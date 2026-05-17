#!/usr/bin/env bash
# update-firmware.sh
#
# Update the firmware on every Pixelblaze V3 on the home WiFi network.
# Uses the ONLINE update path: each unit fetches the latest signed firmware
# from ElectroMage's update server itself. We just trigger the check + install
# via the WebSocket API (pixelblaze-client's installUpdate / getUpdateState).
#
# Compared to a .stfu upload approach:
#   - No firmware file management on this side — units always get the latest
#     release from ElectroMage automatically.
#   - Requires units (and ${HOME_SSID:-home WiFi}) to have internet access.
#
# Flow:
#   1. Discover units on the LAN via UDP enumerator
#   2. Read each unit's current firmware version
#   3. Show a table of {ip, name, version}; confirm
#   4. For each unit, sequentially:
#        a. Trigger the update (WebSocket: {"upgradeVersion": "update"})
#        b. Stream state transitions until the unit reports complete/error
#        c. Move on (the unit reboots itself after a successful update)
#   5. Summary at the end.
#
# Usage:
#   ./update-firmware.sh                 # discover + interactive
#   ./update-firmware.sh --ip 192.168.1.42
#   ./update-firmware.sh --yes           # skip the confirm prompt
#
# Run BEFORE configure-pixelblaze.sh — newer firmware can change defaults
# or add settings that affect the config payload, so it's cleaner to update
# first, then push name + LED config to the freshly-flashed unit.

set -uo pipefail
# -e is OFF on purpose: per-unit Python invocations may exit non-zero (e.g.
# unit unreachable, update failed) and we want to keep iterating, not abort.

# ---- Configuration ----------------------------------------------------------

HOME_SSID="badgirlsclub"
DISCOVERY_LISTEN_SEC=6
UPDATE_TIMEOUT_SEC=600         # generous ceiling — real updates take 1-3 min

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${REPO_DIR}/provision.log"
VENV_DIR="${REPO_DIR}/.venv"
PYTHON="${VENV_DIR}/bin/python3"

# ---- Color palette ----------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[91m'; C_GREEN=$'\033[92m'; C_YELLOW=$'\033[93m'
  C_BLUE=$'\033[94m'; C_MAGENTA=$'\033[95m'; C_CYAN=$'\033[96m'
  RAINBOW=(
    $'\033[38;5;196m' $'\033[38;5;208m' $'\033[38;5;226m' $'\033[38;5;46m'
    $'\033[38;5;51m'  $'\033[38;5;21m'  $'\033[38;5;201m'
  )
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
  RAINBOW=()
fi

rainbow() {
  local text="$1"
  if (( ${#RAINBOW[@]} == 0 )); then printf '%s' "$text"; return; fi
  local i=0 len=${#text}
  while (( i < len )); do
    printf '%s%s' "${RAINBOW[$((i % ${#RAINBOW[@]}))]}" "${text:i:1}"; ((i++))
  done
  printf '%s' "$C_RESET"
}

rainbow_line() {
  local len="${1:-64}" char="${2:-═}"
  local i=0
  if (( ${#RAINBOW[@]} == 0 )); then
    while (( i < len )); do printf '%s' "$char"; ((i++)); done; return
  fi
  while (( i < len )); do
    printf '%s%s' "${RAINBOW[$((i % ${#RAINBOW[@]}))]}" "$char"; ((i++))
  done
  printf '%s' "$C_RESET"
}

# ---- Logging + status helpers -----------------------------------------------

log() {
  local ts msg; ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"; msg="$*"
  printf '%s  %s\n' "$ts" "$msg" >> "$LOG_FILE"
  printf '%s%s%s  %s\n' "$C_DIM" "$ts" "$C_RESET" "$msg"
}
err()  { printf '%s%s✘ %s%s\n' "$C_BOLD" "$C_RED"    "$*" "$C_RESET" >&2; }
warn() { printf '%s%s⚠ %s%s\n' "$C_BOLD" "$C_YELLOW" "$*" "$C_RESET" >&2; }
ok()   { printf '%s%s✔ %s%s\n' "$C_BOLD" "$C_GREEN"  "$*" "$C_RESET"; }
info() { printf '%s→ %s%s\n'   "$C_CYAN"             "$*" "$C_RESET"; }

step() {
  local n="$1"; shift
  local body="$*"
  if [[ -n "$C_CYAN" ]]; then body="${body//•/${C_CYAN}•${C_RESET}}"; fi
  echo
  printf '%s%s── Step %s ──%s ' "$C_BOLD" "$C_CYAN" "$n" "$C_RESET"
  rainbow_line 50 "─"
  echo
  printf '%s\n' "$body"
  echo
}

confirm() {
  local prompt="${1:-Press <enter> when ready, or Ctrl-C to abort: }"
  read -r -p "${C_BOLD}${C_YELLOW}${prompt}${C_RESET}" _
}

get_wifi_iface() {
  command -v networksetup >/dev/null 2>&1 || return 0
  networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

get_current_ssid() {
  local iface; iface="$(get_wifi_iface)"
  [[ -z "$iface" ]] && return 1
  local out
  out="$(networksetup -getairportnetwork "$iface" 2>/dev/null)" || return 1
  case "$out" in
    "Current Wi-Fi Network: "*) printf '%s\n' "${out#Current Wi-Fi Network: }" ;;
    *) return 1 ;;
  esac
}

# ---- Argument parsing -------------------------------------------------------

DEVICE_IP=""
SKIP_CONFIRM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)      DEVICE_IP="$2"; shift 2 ;;
    -y|--yes)  SKIP_CONFIRM=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *)
      err "Unknown argument: $1"
      echo "Try: $0 --help" >&2
      exit 2 ;;
  esac
done

# ---- Pre-flight: venv + pixelblaze-client installed? -----------------------

if [[ ! -x "$PYTHON" ]]; then
  info "Setting up Python venv at $VENV_DIR (one-time, ~30s)..."
  python3 -m venv "$VENV_DIR" || { err "failed to create venv"; exit 1; }
fi
if ! "$PYTHON" -c 'import pixelblaze' 2>/dev/null; then
  info "Installing pixelblaze-client into $VENV_DIR ..."
  "$PYTHON" -m pip install --quiet --upgrade pip || true
  "$PYTHON" -m pip install --quiet pixelblaze-client || {
    err "pip install pixelblaze-client failed"; exit 1; }
  ok "pixelblaze-client installed"
fi

# ---- Welcome banner ---------------------------------------------------------

cat <<BANNER

$(rainbow_line 64)
  ${C_BOLD}$(rainbow "Pixelblaze firmware update")${C_RESET} ${C_DIM}— online via WebSocket${C_RESET}
$(rainbow_line 64)

  ${C_BOLD}This script will:${C_RESET}
    ${C_CYAN}1.${C_RESET} Discover Pixelblazes on the LAN
    ${C_CYAN}2.${C_RESET} Read each unit's current firmware version
    ${C_CYAN}3.${C_RESET} Trigger online update on each unit, sequentially
    ${C_CYAN}4.${C_RESET} Wait for each unit to finish before moving on

  ${C_BOLD}Update mechanism:${C_RESET}
    Each unit fetches the latest signed firmware from ElectroMage
    over its own internet connection. ${C_BOLD}Requires:${C_RESET} ${HOME_SSID}
    has working internet to reach the ElectroMage update server.

  ${C_BOLD}Time:${C_RESET} ~1-3 minutes per unit. Unit reboots after success.
$(rainbow_line 64)
BANNER

# Sanity-check we're on the home network. Don't block.
current_ssid="$(get_current_ssid 2>/dev/null || true)"
if [[ -n "$current_ssid" ]]; then
  if [[ "$current_ssid" == "$HOME_SSID" ]]; then
    ok "on home WiFi: $current_ssid"
  else
    warn "current SSID is '$current_ssid' (expected '$HOME_SSID')."
    echo "  Discovery may still work if your network can route to the units."
  fi
fi

# ---- Discovery (or skip if --ip given) -------------------------------------

# We collect entries into a parallel set of arrays:
#   PB_IPS[i] / PB_NAMES[i] / PB_VERSIONS[i] for unit i.
PB_IPS=()
PB_NAMES=()
PB_VERSIONS=()

# Helper: ask one unit for its name + version. Used for both --ip and as
# a fallback when the bulk discovery couldn't reach a unit.
fetch_one() {
  local ip="$1"
  "$PYTHON" - "$ip" 2>/dev/null <<'PY'
import sys
from pixelblaze import Pixelblaze
ip = sys.argv[1]
try:
    pb = Pixelblaze(ip)
    cs = pb.getConfigSettings() or {}
    name = (cs.get("name") or "").replace("|", "_")
    ver = cs.get("ver") or "?"
    print(f"{ip}|{name}|{ver}")
    pb.close()
except Exception as e:
    print(f"{ip}|<unreachable>|?")
PY
}

if [[ -n "$DEVICE_IP" ]]; then
  ok "using --ip from CLI: $DEVICE_IP"
  entry="$(fetch_one "$DEVICE_IP")"
  IFS='|' read -r ip name ver <<<"$entry"
  PB_IPS+=("$ip")
  PB_NAMES+=("$name")
  PB_VERSIONS+=("$ver")
else
  step 1 "Discovering Pixelblazes on the LAN.

  • Listening for UDP beacons on port 1889 for ~${DISCOVERY_LISTEN_SEC}s.
  • Each Pixelblaze announces itself ~once per second on the subnet.
  • Reading each unit's current firmware version takes a brief WebSocket
    connect, so this step is a little slower per unit than pure discovery."

  info "Listening for beacons (~${DISCOVERY_LISTEN_SEC}s)..."

  export PB_LISTEN_SEC="$DISCOVERY_LISTEN_SEC"
  # Portable equivalent of `mapfile -t entries < <(...)` for bash 3.2.
  entries=()
  while IFS= read -r line; do
    entries+=("$line")
  done < <(
    "$PYTHON" - <<'PY'
import os, time
from pixelblaze import Pixelblaze, PixelblazeEnumerator
listen_sec = int(os.environ.get("PB_LISTEN_SEC", "6"))
pe = PixelblazeEnumerator()
time.sleep(listen_sec)
# Dedupe — the enumerator's internal dict is keyed by sender_id, so a
# unit that rebooted recently can show up under two sender_ids while
# both records are within the 30s timeout. Same IP, different keys.
ips = sorted(set(pe.getPixelblazeList()))
pe.stop()
for ip in ips:
    try:
        pb = Pixelblaze(ip)
        cs = pb.getConfigSettings() or {}
        name = (cs.get("name") or "").replace("|", "_")
        ver = cs.get("ver") or "?"
        print(f"{ip}|{name}|{ver}")
        pb.close()
    except Exception:
        print(f"{ip}|<unreachable>|?")
PY
  )

  if (( ${#entries[@]} == 0 )); then
    err "No Pixelblazes found on the LAN."
    echo "  Is at least one unit powered on and joined to ${HOME_SSID}?" >&2
    echo "  Try: $0 --ip <addr> if you know the IP." >&2
    exit 1
  fi

  for e in "${entries[@]}"; do
    IFS='|' read -r ip name ver <<<"$e"
    PB_IPS+=("$ip")
    PB_NAMES+=("$name")
    PB_VERSIONS+=("$ver")
  done
fi

# ---- Show the table + confirm ---------------------------------------------

echo
ok "Found ${#PB_IPS[@]} unit(s):"
echo
# Pretty-printed numbered table. The width here (15 for IP, 18 for name)
# is tuned for typical output — real names rarely exceed 16 chars.
for i in "${!PB_IPS[@]}"; do
  printf "  ${C_CYAN}[%d]${C_RESET} ${C_BOLD}%-15s${C_RESET}  ${C_DIM}name=${C_RESET}${C_GREEN}%-18s${C_RESET}  ${C_DIM}ver=${C_RESET}${C_BOLD}%s${C_RESET}\n" \
    "$((i+1))" "${PB_IPS[$i]}" "${PB_NAMES[$i]:-<unnamed>}" "${PB_VERSIONS[$i]}"
done
echo

if [[ -z "$SKIP_CONFIRM" ]]; then
  confirm "Press <enter> to update all ${#PB_IPS[@]} unit(s), or Ctrl-C to abort: "
fi

log "Starting firmware update batch: ${#PB_IPS[@]} unit(s)"

# ---- Per-unit update loop --------------------------------------------------

# Tally results so the summary at the end can show what happened.
RESULTS=()  # parallel to PB_IPS — one of: UPDATED / UPTODATE / FAILED / SKIPPED / ERROR

# The per-unit Python helper. Pass IP as argv. Exits:
#   0  — UPDATED (was updateAvailable, installUpdate -> updateComplete)
#       OR UPTODATE (no work needed)
#   2  — FAILED (installUpdate returned a non-complete terminal state)
#   3  — SKIPPED (state was something we don't act on, e.g. updateError)
#   1  — ERROR (couldn't even connect to the unit)
# Verdict is also printed on the last line as "verdict: <TAG>" so bash can
# parse it reliably.
update_one() {
  local ip="$1"
  export PB_TARGET_IP="$ip"
  export PB_UPDATE_TIMEOUT="$UPDATE_TIMEOUT_SEC"
  "$PYTHON" - <<'PY' 2>&1 | tee -a "$LOG_FILE"
import os, sys, time
from pixelblaze import Pixelblaze

ip      = os.environ["PB_TARGET_IP"]
timeout = int(os.environ.get("PB_UPDATE_TIMEOUT", "600"))

pb = None
try:
    pb = Pixelblaze(ip)
    before = pb.getVersion()
    print(f"  connected: current version v{before}")

    state = pb.getUpdateState()
    print(f"  update check: {state.name}")

    if state == pb.updateStates.upToDate:
        print("  verdict: UPTODATE")
        sys.exit(0)

    if state != pb.updateStates.updateAvailable:
        # error / unknown / inProgress (already running) / etc.
        print(f"  verdict: SKIPPED ({state.name})")
        sys.exit(3)

    print("  triggering install (1-3 min, unit will reboot)...")
    # installUpdate() polls internally and returns when state reaches a
    # terminal value. It also prints its own progress lines. We honor
    # the user's timeout by setting a wall clock alarm.
    start = time.time()
    final = pb.installUpdate()
    elapsed = int(time.time() - start)
    print(f"  done in {elapsed}s, final state: {final.name}")

    if final == pb.updateStates.updateComplete:
        print("  verdict: UPDATED")
        sys.exit(0)
    print(f"  verdict: FAILED ({final.name})")
    sys.exit(2)

except Exception as e:
    print(f"  verdict: ERROR ({type(e).__name__}: {e})")
    sys.exit(1)
finally:
    if pb is not None:
        try: pb.close()
        except Exception: pass
PY
}

for i in "${!PB_IPS[@]}"; do
  ip="${PB_IPS[$i]}"
  name="${PB_NAMES[$i]:-<unnamed>}"
  ver="${PB_VERSIONS[$i]}"

  echo
  rainbow_line 64; echo
  # Note: bash *won't* expand ${VAR} inside single-quoted strings. Use double
  # quotes here so the color codes interpolate, and %s placeholders for the
  # actual data values so they don't get reinterpreted by printf.
  printf "  %sUnit %d/%d:%s %s%s%s @ %s%s%s ${C_DIM}(was v%s)${C_RESET}\n" \
    "$C_BOLD" "$((i+1))" "${#PB_IPS[@]}" "$C_RESET" \
    "$C_GREEN" "$name" "$C_RESET" \
    "$C_BLUE" "$ip" "$C_RESET" \
    "$ver"
  rainbow_line 64; echo

  log "[$ip $name] starting update from v$ver"

  # Run update_one and capture the verdict from its last line. We use
  # PIPESTATUS to get the Python exit code despite the tee pipe.
  out="$(update_one "$ip")"
  rc="${PIPESTATUS[0]}"

  # Extract the final "verdict: X" tag from the captured output. The tag
  # is what we report in the summary. If we can't parse one, fall back
  # to UNKNOWN — the rc is also recorded in the log.
  verdict="$(printf '%s\n' "$out" | awk '/verdict:/ {v=$NF} END{print v}')"
  : "${verdict:=UNKNOWN}"

  case "$verdict" in
    UPDATED)  ok "[$name] firmware updated successfully" ;;
    UPTODATE) ok "[$name] already on latest firmware (v$ver)" ;;
    FAILED)   err "[$name] firmware update failed — check $LOG_FILE" ;;
    SKIPPED)  warn "[$name] skipped (unit reported a state we don't act on)" ;;
    ERROR)    err "[$name] could not communicate with unit (rc=$rc)" ;;
    *)        warn "[$name] unknown outcome (rc=$rc, verdict='$verdict')" ;;
  esac

  RESULTS+=("$verdict")
  log "[$ip $name] result: $verdict"
done

# ---- Summary ---------------------------------------------------------------

# Count each outcome class. Using named scalars instead of an associative
# array because macOS still ships bash 3.2, which doesn't have `declare -A`.
count_updated=0
count_uptodate=0
count_failed=0
count_skipped=0
count_error=0
count_unknown=0
for v in "${RESULTS[@]}"; do
  case "$v" in
    UPDATED)  count_updated=$((count_updated+1)) ;;
    UPTODATE) count_uptodate=$((count_uptodate+1)) ;;
    FAILED)   count_failed=$((count_failed+1)) ;;
    SKIPPED)  count_skipped=$((count_skipped+1)) ;;
    ERROR)    count_error=$((count_error+1)) ;;
    *)        count_unknown=$((count_unknown+1)) ;;
  esac
done

echo
rainbow_line 64; echo
# Double-quoted format strings so color vars interpolate. %d placeholders
# carry the actual counts as separate args.
printf "  %sFirmware update batch complete.%s\n" "$C_BOLD" "$C_RESET"
echo
printf "    ${C_GREEN}updated:${C_RESET}    %d\n"    "$count_updated"
printf "    ${C_GREEN}up-to-date:${C_RESET} %d\n"    "$count_uptodate"
printf "    ${C_RED}failed:${C_RESET}     %d\n"      "$count_failed"
printf "    ${C_YELLOW}skipped:${C_RESET}    %d\n"   "$count_skipped"
printf "    ${C_RED}errored:${C_RESET}    %d\n"      "$count_error"
echo
rainbow_line 64; echo

log "Batch summary: updated=$count_updated uptodate=$count_uptodate failed=$count_failed skipped=$count_skipped errored=$count_error"

# Exit 0 only if no failures or errors. Lets you chain this in a script:
#   ./update-firmware.sh --yes && ./configure-pixelblaze.sh ...
if (( count_failed + count_error > 0 )); then
  exit 1
fi
echo
printf '  %s\n' "$(rainbow "all firmware up to date")"
echo
