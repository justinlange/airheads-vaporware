#!/usr/bin/env bash
# configure-pixelblaze.sh
#
# Configure a Pixelblaze V3 that's already on the home WiFi network.
# Use this for ANY post-WiFi-setup config: changing the name, LED type,
# color order, pixel count. Run as many times as you like — it's idempotent
# and reconnects to whichever unit you pick.
#
# Compared to provision-pixelblaze.sh:
#   - You don't need to be on the unit's setup AP.
#   - You don't need to enter WiFi credentials (already done).
#   - Unit is auto-discovered via UDP beacons (PixelblazeEnumerator).
#   - Naming happens AFTER discovery so you can see the unit's current
#     name and IP before deciding what to call it.
#
# Flow:
#   1. Listen ~6s for Pixelblaze beacons on UDP port 1889
#   2. Connect briefly to each found unit to read its current name
#   3. Show the list, let user pick one (auto-pick if exactly one)
#   4. Prompt for a new name (default: the unit's current name)
#   5. Push name + LED config over WebSocket; verify; save to flash
#   6. Update provisioned.json (upsert by current name)
#
# Usage:
#   ./configure-pixelblaze.sh                       # full interactive
#   ./configure-pixelblaze.sh --ip 192.168.1.42     # skip discovery
#   ./configure-pixelblaze.sh --name kitchen-1      # skip name prompt
#   ./configure-pixelblaze.sh --count 144           # override pixel count
#
# All three flags can combine. macOS-tested; the Python-driven WebSocket
# work is OS-agnostic but the SSID auto-detect is macOS-only.

set -uo pipefail
# -e is intentionally OFF: several blocks need to capture rc from a piped
# Python invocation and report cleanly, which is awkward under -e.

# ---- Configuration ----------------------------------------------------------

HOME_SSID="badgirlsclub"          # the home WiFi the units are joined to
PIXEL_COUNT_DEFAULT=68            # default WS2812 strand size
LED_TYPE=2                        # WS2812 / NeoPixel (per pixelblaze-client ledTypes enum)
DATA_SPEED=2250000                # 2.25 MHz, V3 default for WS2812
COLOR_ORDER="GRB"                 # most WS2812B strips are physically GRB
NAME_PREFIX="pb-"                 # prefix for auto-generated names
DISCOVERY_LISTEN_SEC=6            # UDP beacon listen window — units beacon ~1/s

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${REPO_DIR}/provision.log"
MAP_FILE="${REPO_DIR}/provisioned.json"
VENV_DIR="${REPO_DIR}/.venv"
PYTHON="${VENV_DIR}/bin/python3"

# ---- Color palette ----------------------------------------------------------
# Same setup as provision-pixelblaze.sh: auto-disabled when stdout isn't a
# TTY or when NO_COLOR is set (https://no-color.org).
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

# ---- Interactive helpers ----------------------------------------------------

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

# Find the Mac's WiFi interface (e.g. en0) by parsing networksetup output.
get_wifi_iface() {
  command -v networksetup >/dev/null 2>&1 || return 0
  networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

# Echo the SSID we're currently joined to, or return 1 if unknown.
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

# Suggest the next pb-NN sequence name based on what's already in
# provisioned.json. Used as the default when no current_name is known.
pick_default_name() {
  local idx=1
  if [[ -f "$MAP_FILE" ]]; then
    idx="$(python3 - "$MAP_FILE" "$NAME_PREFIX" <<'PY'
import json, re, sys
path, prefix = sys.argv[1], sys.argv[2]
try:
    entries = json.load(open(path))
except Exception:
    entries = []
nums = []
for e in entries:
    m = re.match(rf"^{re.escape(prefix)}(\d+)$", e.get("name", ""))
    if m:
        nums.append(int(m.group(1)))
print((max(nums) + 1) if nums else 1)
PY
)"
  fi
  printf '%s%02d' "$NAME_PREFIX" "$idx"
}

# ---- Argument parsing -------------------------------------------------------

DEVICE_NAME=""
DEVICE_IP=""
PIXEL_COUNT="$PIXEL_COUNT_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   DEVICE_NAME="$2"; shift 2 ;;
    --ip)     DEVICE_IP="$2";   shift 2 ;;
    --count)  PIXEL_COUNT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      err "Unknown argument: $1"
      echo "Try: $0 --help" >&2
      exit 2 ;;
  esac
done

# ---- Pre-flight: venv + pixelblaze-client installed? -----------------------

# Same venv as provision-pixelblaze.sh — the two scripts share .venv.
# First run on a fresh checkout creates it; otherwise this is instant.
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
  ${C_BOLD}$(rainbow "Pixelblaze configure")${C_RESET} ${C_DIM}— LAN edition${C_RESET}
$(rainbow_line 64)

  ${C_BOLD}Use this script to (re)configure a unit already on home WiFi.${C_RESET}

  Steps:
    ${C_CYAN}1.${C_RESET} Discover units on the LAN ${C_DIM}(UDP beacons, ~${DISCOVERY_LISTEN_SEC}s)${C_RESET}
    ${C_CYAN}2.${C_RESET} Pick a unit ${C_DIM}(skipped if exactly one is found)${C_RESET}
    ${C_CYAN}3.${C_RESET} Pick a name ${C_DIM}(default: the unit's current name)${C_RESET}
    ${C_CYAN}4.${C_RESET} Push config + record to provisioned.json

  ${C_BOLD}Fixed config (every unit):${C_RESET}
    ${C_DIM}pixelCount${C_RESET}  = ${C_GREEN}${C_BOLD}${PIXEL_COUNT}${C_RESET}
    ${C_DIM}ledType${C_RESET}     = ${C_GREEN}${C_BOLD}${LED_TYPE}${C_RESET}  ${C_DIM}(WS2812B / NeoPixel)${C_RESET}
    ${C_DIM}colorOrder${C_RESET}  = ${C_GREEN}${C_BOLD}${COLOR_ORDER}${C_RESET}
    ${C_DIM}dataSpeed${C_RESET}   = ${C_GREEN}${C_BOLD}${DATA_SPEED}${C_RESET}
$(rainbow_line 64)
BANNER

# Sanity-check we're on the home network. Don't block — VPNs / bridged
# networks / multi-homed setups can still see the units. Just warn.
current_ssid="$(get_current_ssid 2>/dev/null || true)"
if [[ -n "$current_ssid" ]]; then
  if [[ "$current_ssid" == "$HOME_SSID" ]]; then
    ok "on home WiFi: $current_ssid"
  else
    warn "current SSID is '$current_ssid' (expected '$HOME_SSID')."
    echo "  Discovery may still work if your network can route to the units."
  fi
else
  info "current SSID: (could not auto-detect — relying on UDP discovery)"
fi

confirm "Press <enter> to begin, or Ctrl-C to abort: "

# ---- Step 1: discover (or skip if --ip was given) --------------------------

# Variables we'll fill in: PB_IP (the unit's home-network IP) and
# CURRENT_NAME (the unit's currently-saved device name, if known).
PB_IP=""
CURRENT_NAME=""

if [[ -n "$DEVICE_IP" ]]; then
  # --ip path: skip discovery, but still fetch the current name so the
  # Step-3 prompt can default to it.
  PB_IP="$DEVICE_IP"
  ok "using --ip from CLI: $PB_IP"
  CURRENT_NAME="$("$PYTHON" - "$PB_IP" 2>/dev/null <<'PY'
import sys
from pixelblaze import Pixelblaze
try:
    pb = Pixelblaze(sys.argv[1])
    cs = pb.getConfigSettings() or {}
    print(cs.get("name", ""))
    pb.close()
except Exception:
    pass  # leave empty; Step 3 falls back to pick_default_name
PY
)"
  CURRENT_NAME="${CURRENT_NAME//$'\n'/}"  # strip stray newlines
else
  step 1 "Discovering Pixelblazes on the LAN.

  • Listening for UDP beacons on port 1889 for ~${DISCOVERY_LISTEN_SEC}s.
  • Each Pixelblaze announces itself ~once per second, so a few seconds
    is enough to collect every unit on the subnet.
  • If yours doesn't show up: confirm it's powered on, joined to
    ${HOME_SSID}, and on the same subnet as this Mac. You can also
    pass --ip <addr> to skip discovery entirely."

  info "Listening for beacons (~${DISCOVERY_LISTEN_SEC}s)..."

  # Run discovery + per-IP name fetch in one Python process. Output is
  # one line per unit, formatted "IP|NAME". We read it into an array via
  # a portable while-read loop (mapfile is bash 4+; macOS still ships 3.2).
  export PB_LISTEN_SEC="$DISCOVERY_LISTEN_SEC"
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
# Dedupe by IP — see update-firmware.sh for why the enumerator can
# return the same address under multiple sender_ids.
ips = sorted(set(pe.getPixelblazeList()))
pe.stop()
for ip in ips:
    try:
        pb = Pixelblaze(ip)
        cs = pb.getConfigSettings() or {}
        name = (cs.get("name") or "").replace("|", "_")  # protect delimiter
        print(f"{ip}|{name}")
        pb.close()
    except Exception as e:
        print(f"{ip}|<unreachable: {type(e).__name__}>")
PY
  )

  count="${#entries[@]}"
  if (( count == 0 )); then
    err "No Pixelblazes found on the LAN."
    echo "  Possible causes:" >&2
    echo "    • unit not powered on, or still booting" >&2
    echo "    • unit hasn't yet joined ${HOME_SSID}" >&2
    echo "    • this Mac is on a different subnet (e.g. VPN, guest WiFi)" >&2
    echo "    • firewall blocking UDP 1889" >&2
    echo "  Workaround: pass --ip <addr> if you know the unit's IP." >&2
    exit 1
  fi

  echo
  ok "Found $count unit(s):"
  echo
  # Pretty-print numbered list. Bold IP, green name. Numbering is 1-based
  # to match the user-facing prompt below.
  for i in "${!entries[@]}"; do
    IFS='|' read -r ip name <<<"${entries[$i]}"
    printf "  ${C_CYAN}[%d]${C_RESET} ${C_BOLD}%-15s${C_RESET}  ${C_DIM}name=${C_RESET}${C_GREEN}%s${C_RESET}\n" \
      "$((i+1))" "$ip" "${name:-<no name>}"
  done
  echo

  if (( count == 1 )); then
    pick=1
    info "Only one unit found — selecting automatically."
  else
    # Loop until valid input. Empty input or anything non-numeric reprompts.
    while true; do
      read -r -p "${C_BOLD}${C_YELLOW}Pick a unit by number [1-$count]: ${C_RESET}" pick
      if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= count )); then
        break
      fi
      warn "Not a valid choice."
    done
  fi

  # Split the chosen entry back into IP and current name.
  IFS='|' read -r PB_IP CURRENT_NAME <<<"${entries[$((pick-1))]}"
  # If discovery couldn't reach the unit, the "name" slot will be the
  # error placeholder like "<unreachable: ...>". Treat that as empty so
  # we don't suggest a stupid default.
  case "$CURRENT_NAME" in
    "<unreachable:"*) CURRENT_NAME="" ;;
  esac
fi

log "Selected unit: $PB_IP (current name: ${CURRENT_NAME:-<unknown>})"

# ---- Step 2/3: pick a name -------------------------------------------------

# Default for the prompt: the unit's current name if we know it, else the
# next pb-NN slot from the sequence. The user can override either way by
# typing something else, or accept the default with <enter>.
if [[ -n "$DEVICE_NAME" ]]; then
  ok "using --name from CLI: $DEVICE_NAME"
else
  if [[ -n "$CURRENT_NAME" ]]; then
    default_name="$CURRENT_NAME"
  else
    default_name="$(pick_default_name)"
  fi

  step 2 "Name this unit.

  • Selected unit: ${C_BOLD}${PB_IP}${C_RESET}
  • Current name:  ${C_GREEN}${CURRENT_NAME:-<unknown>}${C_RESET}
  • Press <enter> to keep '${C_GREEN}${default_name}${C_RESET}', or
    type a new name (e.g. 'kitchen-1', 'living-room', 'front-window')."

  read -r -p "${C_BOLD}${C_YELLOW}Name for this unit [${default_name}]: ${C_RESET}" entered_name
  DEVICE_NAME="${entered_name:-$default_name}"
fi

log "Configuring $PB_IP: name=$DEVICE_NAME count=$PIXEL_COUNT ledType=$LED_TYPE colorOrder=$COLOR_ORDER"

# ---- Step 3: push config over WebSocket ------------------------------------

# Same single-message bundle as provision-pixelblaze.sh, just pointed at
# the unit's home-network IP instead of 192.168.4.1.
export PB_IP_FOR_PUSH="$PB_IP"
export PB_NAME="$DEVICE_NAME"
export PB_COUNT="$PIXEL_COUNT"
export PB_LED_TYPE="$LED_TYPE"
export PB_DATA_SPEED="$DATA_SPEED"
export PB_COLOR_ORDER="$COLOR_ORDER"

"$PYTHON" - <<'PY' 2>&1 | tee -a "$LOG_FILE"
import json, os, sys
from pixelblaze import Pixelblaze

ip          = os.environ["PB_IP_FOR_PUSH"]
name        = os.environ["PB_NAME"]
count       = int(os.environ["PB_COUNT"])
ledType     = int(os.environ["PB_LED_TYPE"])
speed       = int(os.environ["PB_DATA_SPEED"])
colorOrder  = os.environ["PB_COLOR_ORDER"]

pb = Pixelblaze(ip)

# One bundled message → single atomic flash write. Same key set as the
# provision script — see those comments for details on each key.
cmd = {
    "name":            name,
    "ledType":         ledType,
    "dataSpeed":       speed,
    "pixelCount":      count,
    "colorOrder":      colorOrder,
    "discoveryEnable": True,
    "save":            True,
}
print("send:", json.dumps(cmd))
pb.wsSendJson(cmd)

hw = pb.getConfigSettings() or {}
echo = {
    "name":        hw.get("name"),
    "ledType":     hw.get("ledType"),
    "pixelCount":  hw.get("pixelCount"),
    "dataSpeed":   hw.get("dataSpeed"),
    "colorOrder":  hw.get("colorOrder"),
    "discovery":   hw.get("discoveryEnable"),
}
print("read-back:", json.dumps(echo, indent=2))

# Hard-fail on any disagreement so we don't write a misleading row to
# provisioned.json. dataSpeed sometimes settles to a slightly different
# value than what we sent (firmware rounds), so we don't strictly check it.
mismatches = []
if echo["name"] != name:                  mismatches.append(("name", echo["name"], name))
if int(echo["ledType"] or 0) != ledType:  mismatches.append(("ledType", echo["ledType"], ledType))
if int(echo["pixelCount"] or 0) != count: mismatches.append(("pixelCount", echo["pixelCount"], count))
if echo["colorOrder"] != colorOrder:      mismatches.append(("colorOrder", echo["colorOrder"], colorOrder))
if mismatches:
    print("VERIFY FAILED:", mismatches, file=sys.stderr)
    sys.exit(2)

pb.close()
print("config OK")
PY
PY_RC=${PIPESTATUS[0]}

if [[ $PY_RC -ne 0 ]]; then
  err "Config push failed (rc=$PY_RC). See $LOG_FILE."
  log "ERROR: Config push failed (rc=$PY_RC)"
  exit 1
fi
ok "Config push OK"
log "Config push OK"

# ---- Step 4: upsert into provisioned.json ----------------------------------

# Strategy:
#   1. If a row already exists with name == CURRENT_NAME (the name the unit
#      had at the start of this run), update that row in place. This handles
#      the rename case: old row "jordan" gets overwritten when we configure
#      the same unit with name "kitchen-1".
#   2. Otherwise append a new row.
#
# Atomic write: build new list, write to .tmp, rename. The original file
# is never partially-written, even if we get killed mid-write.
export PB_MAP_FILE="$MAP_FILE"
export PB_HOME_IP="$PB_IP"
export PB_HOME_SSID="${current_ssid:-}"
export PB_CURRENT_NAME="$CURRENT_NAME"

"$PYTHON" - <<'PY' | tee -a "$LOG_FILE"
import json, os, time
from pathlib import Path

map_file = Path(os.environ["PB_MAP_FILE"])
new_entry = {
    "name":       os.environ["PB_NAME"],
    "pixelCount": int(os.environ["PB_COUNT"]),
    "ledType":    int(os.environ["PB_LED_TYPE"]),
    "timestamp":  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "apSsid":     "",  # n/a in the LAN flow
    "homeIp":     os.environ["PB_HOME_IP"],
    "homeSsid":   os.environ.get("PB_HOME_SSID", ""),
}

if map_file.exists():
    text = map_file.read_text().strip()
    data = json.loads(text) if text else []
else:
    data = []

# Upsert by the name the unit had BEFORE this run (so renames update the
# existing row instead of duplicating it).
current_name = os.environ.get("PB_CURRENT_NAME", "")
matched = False
if current_name:
    for i, e in enumerate(data):
        if e.get("name") == current_name:
            data[i] = {**e, **new_entry}
            matched = True
            break
if not matched:
    data.append(new_entry)

tmp = map_file.with_suffix(map_file.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
tmp.replace(map_file)
verb = "updated" if matched else "appended"
print(f"{verb} {map_file.name}: {new_entry['name']} @ {new_entry['homeIp']}")
PY

log "Done: $DEVICE_NAME @ $PB_IP"

# ---- Rainbow finale --------------------------------------------------------

echo
rainbow_line 64; echo
printf '  %s%s%s configured!%s  %s\n' "$C_BOLD" "$C_GREEN" "$DEVICE_NAME" "$C_RESET" "$(rainbow "all done")"
echo
rainbow_line 64; echo
echo
