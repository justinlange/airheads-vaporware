#!/usr/bin/env bash
# provision-pixelblaze.sh
#
# Manual provisioning helper for a SINGLE Pixelblaze V3.
# Run this AFTER you've connected this Mac to the unit's pixelblaze_XXXXXX AP.
#
# What this script does, in order:
#   1. Verifies you're actually on the unit's AP (HTTP ping to 192.168.4.1).
#   2. Pushes ledType / pixelCount / dataSpeed / discoveryEnable / name in one
#      WebSocket message with save=true, so it's a single atomic flash write.
#   3. Reads the config back and prints it so you can eyeball that it stuck.
#   4. Opens the unit's web UI so you can enter home WiFi credentials in the
#      WiFi tab. We do NOT push WiFi creds via the WebSocket — the JSON shape
#      isn't exposed in pixelblaze-client, and instructions.md is explicit
#      about not guessing it. The web UI is the firmware's supported path.
#   5. After you confirm WiFi was saved, appends a row to provisioned.json
#      so there's a record of which physical unit got which name.
#
# Usage:
#   ./provision-pixelblaze.sh                       # auto-name (next pb-NN)
#   ./provision-pixelblaze.sh --name pb-07
#   ./provision-pixelblaze.sh --name pb-07 --count 144
#
# Targets macOS (uses `open` to launch the browser). The WebSocket part is
# OS-agnostic since it runs through Python.

set -uo pipefail
# Note: -e is intentionally OFF. Several steps need to capture a non-zero
# exit code from a piped Python invocation and report cleanly, which is
# awkward under -e. We check return codes explicitly instead.

# ---- Configuration ----------------------------------------------------------

# These match instructions.md. Change here, not at the call site.
AP_IP="192.168.4.1"             # Pixelblaze always serves its setup AP on this IP
WS_PORT=81                       # Pixelblaze WebSocket API port (informational only)
HOME_SSID="badgirlsclub"         # for the human-readable prompt; user types it into the web UI
PIXEL_COUNT_DEFAULT=68           # default strand size for these units
# Pixelblaze V3 ledType enum (verified against pixelblaze-client source):
#   0 = noLeds, 1 = APA102/DotStar, 2 = WS2812/NeoPixel/SK6822,
#   3 = WS2801, 4 = bufferedWS2812 (v2 only), 5 = OutputExpander.
# instructions.md says ledType=1 for WS2812 — that's wrong, it's APA102.
LED_TYPE=2                       # 2 = WS2812B / NeoPixel
# Default data speed for WS2812 on V3 per the library is 2.25 MHz (not the
# 2 MHz quoted in instructions.md — that's the APA102 default).
DATA_SPEED=2250000               # 2.25 MHz, V3 default for WS2812
# Color order on the wire. Pixelblaze accepts strings: "RGB", "GRB", "BGR",
# "RBG", "BRG", "GBR", plus "RGBW"/"GRBW"/"RGB-W"/"GRB-W" for RGBW strips.
# Our WS2812B strips are physically wired GRB.
COLOR_ORDER="GRB"
NAME_PREFIX="pb-"                # prefix for auto-generated names (pb-01, pb-02, ...)

# Resolve paths relative to this script so the script works regardless of cwd.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${REPO_DIR}/provision.log"
MAP_FILE="${REPO_DIR}/provisioned.json"
# Self-contained venv lives inside the repo. Keeps pixelblaze-client and its
# (sizable) deps off the user's system Python — Homebrew/macOS Python is
# externally-managed and refuses plain `pip install` anyway. Created on
# first run if missing.
VENV_DIR="${REPO_DIR}/.venv"
PYTHON="${VENV_DIR}/bin/python3"

# ---- Color palette ----------------------------------------------------------

# ANSI colors. Auto-disabled when stdout isn't a TTY (so piping/redirecting
# stays clean) or when NO_COLOR is set (https://no-color.org). 256-color
# codes are used for the rainbow because the basic 16 don't include orange.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[91m'
  C_GREEN=$'\033[92m'
  C_YELLOW=$'\033[93m'
  C_BLUE=$'\033[94m'
  C_MAGENTA=$'\033[95m'
  C_CYAN=$'\033[96m'
  RAINBOW=(
    $'\033[38;5;196m'  # red
    $'\033[38;5;208m'  # orange
    $'\033[38;5;226m'  # yellow
    $'\033[38;5;46m'   # green
    $'\033[38;5;51m'   # cyan
    $'\033[38;5;21m'   # blue
    $'\033[38;5;201m'  # violet
  )
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
  RAINBOW=()
fi

# Print text with each character cycled through the rainbow palette.
# Falls back to plain output when colors are disabled.
rainbow() {
  local text="$1"
  if (( ${#RAINBOW[@]} == 0 )); then
    printf '%s' "$text"
    return
  fi
  local i=0 len=${#text}
  while (( i < len )); do
    printf '%s%s' "${RAINBOW[$((i % ${#RAINBOW[@]}))]}" "${text:i:1}"
    ((i++))
  done
  printf '%s' "$C_RESET"
}

# Print a horizontal rule of $1 chars (default 64), each in a rainbow color.
rainbow_line() {
  local len="${1:-64}" char="${2:-═}"
  local i=0
  if (( ${#RAINBOW[@]} == 0 )); then
    # No-color fallback: still respect the caller's char so a "── Step 1 ──"
    # heading isn't followed by jarring "=" runs.
    while (( i < len )); do printf '%s' "$char"; ((i++)); done
    return
  fi
  while (( i < len )); do
    printf '%s%s' "${RAINBOW[$((i % ${#RAINBOW[@]}))]}" "$char"
    ((i++))
  done
  printf '%s' "$C_RESET"
}

# ---- Logging helper ---------------------------------------------------------

# Writes a UTC-timestamped line to stdout (colored, dim timestamp) and to
# the log file (plain — no escape sequences cluttering the log).
log() {
  local ts msg
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  msg="$*"
  printf '%s  %s\n' "$ts" "$msg" >> "$LOG_FILE"
  printf '%s%s%s  %s\n' "$C_DIM" "$ts" "$C_RESET" "$msg"
}

# Severity-tagged variants. err goes to stderr (so it survives stdout
# redirection); warn/ok/info go to stdout. None of these are logged to the
# file — call log() separately when you want a trace entry.
err()  { printf '%s%s✘ %s%s\n' "$C_BOLD" "$C_RED"    "$*" "$C_RESET" >&2; }
warn() { printf '%s%s⚠ %s%s\n' "$C_BOLD" "$C_YELLOW" "$*" "$C_RESET" >&2; }
ok()   { printf '%s%s✔ %s%s\n' "$C_BOLD" "$C_GREEN"  "$*" "$C_RESET"; }
info() { printf '%s→ %s%s\n'   "$C_CYAN"             "$*" "$C_RESET"; }

# ---- Interactive helpers ----------------------------------------------------

# Print a numbered step header followed by a description. The header gets
# a rainbow rule for visual punch; bullets in the body are tinted cyan.
step() {
  local n="$1"; shift
  local body="$*"
  # Tint bullets so the eye finds them fast.
  if [[ -n "$C_CYAN" ]]; then
    body="${body//•/${C_CYAN}•${C_RESET}}"
  fi
  echo
  printf '%s%s── Step %s ──%s ' "$C_BOLD" "$C_CYAN" "$n" "$C_RESET"
  rainbow_line 50 "─"
  echo
  printf '%s\n' "$body"
  echo
}

# Block until the user presses enter. Prompt is bold-yellow so it stands
# out from the surrounding text. Ctrl-C aborts as normal.
confirm() {
  local prompt="${1:-Press <enter> when ready, or Ctrl-C to abort: }"
  read -r -p "${C_BOLD}${C_YELLOW}${prompt}${C_RESET}" _
}

# Find this Mac's WiFi interface name (e.g. "en0"). Parses networksetup
# output: each "Hardware Port: ..." block is followed by a "Device: ..."
# line — when the port is "Wi-Fi" we want the device on the next line.
# Returns empty if no WiFi port is found (e.g. running on Linux).
get_wifi_iface() {
  command -v networksetup >/dev/null 2>&1 || return 0
  networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

# Echo the SSID the Mac is currently joined to. Returns 1 if not on WiFi
# or if we can't determine it. Used to (a) auto-record the AP SSID in
# provisioned.json and (b) warn if the user said they joined the AP but
# is actually still on the home network.
get_current_ssid() {
  local iface; iface="$(get_wifi_iface)"
  [[ -z "$iface" ]] && return 1
  local out
  out="$(networksetup -getairportnetwork "$iface" 2>/dev/null)" || return 1
  # Output format: "Current Wi-Fi Network: SOME_SSID"
  # If not associated, output starts with "You are not associated".
  case "$out" in
    "Current Wi-Fi Network: "*) printf '%s\n' "${out#Current Wi-Fi Network: }" ;;
    *) return 1 ;;
  esac
}

# Compute a default device name by scanning provisioned.json for the highest
# existing pb-NN index and adding 1. Falls back to pb-01 on a fresh map file.
# Used as the suggested default in the interactive Step 3 prompt.
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
  # Zero-pad to 2 digits (pb-01, pb-02, ...). Bump the width if you ever
  # provision more than 99 units.
  printf '%s%02d' "$NAME_PREFIX" "$idx"
}

# Track the AP SSID we ended up on, for provisioned.json. Initialized
# empty so `set -u` doesn't trip on it before Step 2 runs.
AP_SSID=""

# ---- Argument parsing -------------------------------------------------------

DEVICE_NAME=""
PIXEL_COUNT="$PIXEL_COUNT_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      DEVICE_NAME="$2"; shift 2 ;;
    --count)
      PIXEL_COUNT="$2"; shift 2 ;;
    -h|--help)
      # Print the comment block at the top of this file as the help text.
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Try: $0 --help" >&2
      exit 2 ;;
  esac
done

# Note: the device name is chosen interactively in Step 3 (after the user
# joins the unit's AP), unless --name was passed on the CLI. We delay the
# default-name lookup until that step too, so it reflects the latest state
# of provisioned.json even if the user provisions multiple units in one
# session via repeated invocations.

# ---- Pre-flight: venv + pixelblaze-client installed? ------------------------

# We isolate Python deps into ${REPO_DIR}/.venv so we don't fight macOS's
# externally-managed system Python. First run creates the venv and installs
# pixelblaze-client; subsequent runs are instant.
if [[ ! -x "$PYTHON" ]]; then
  info "Setting up Python venv at $VENV_DIR (one-time, ~30s)..."
  python3 -m venv "$VENV_DIR" || {
    err "failed to create venv. Is python3 installed?"
    exit 1
  }
fi

if ! "$PYTHON" -c 'import pixelblaze' 2>/dev/null; then
  info "Installing pixelblaze-client into $VENV_DIR ..."
  "$PYTHON" -m pip install --quiet --upgrade pip || true
  "$PYTHON" -m pip install --quiet pixelblaze-client || {
    err "pip install pixelblaze-client failed."
    echo "  Try manually: $PYTHON -m pip install pixelblaze-client" >&2
    exit 1
  }
  ok "pixelblaze-client installed"
fi

# ---- Welcome banner ---------------------------------------------------------

# Show the user what's about to happen and what values we'll write, BEFORE
# they take any physical action. Last chance to Ctrl-C if anything is wrong.
# The heredoc is unquoted so $(...) and ${...} expand inside it — that's
# how the rainbow borders and the colored values get in.
cat <<BANNER

$(rainbow_line 64)
  ${C_BOLD}$(rainbow "Pixelblaze provisioning")${C_RESET} ${C_DIM}— single unit${C_RESET}
$(rainbow_line 64)

  ${C_BOLD}This script will walk you through:${C_RESET}
    ${C_CYAN}1.${C_RESET} Power on the Pixelblaze
    ${C_CYAN}2.${C_RESET} Connect this Mac to the unit's setup AP
    ${C_CYAN}3.${C_RESET} Pick a friendly name for this unit ${C_DIM}(interactive)${C_RESET}
    ${C_CYAN}4.${C_RESET} Push LED config over WebSocket ${C_DIM}(automated)${C_RESET}
    ${C_CYAN}5.${C_RESET} Enter home WiFi creds in the unit's web UI
    ${C_CYAN}6.${C_RESET} Record the unit in provisioned.json ${C_DIM}(automated)${C_RESET}

  ${C_BOLD}Fixed config (every unit):${C_RESET}
    ${C_DIM}pixelCount${C_RESET}  = ${C_GREEN}${C_BOLD}${PIXEL_COUNT}${C_RESET}
    ${C_DIM}ledType${C_RESET}     = ${C_GREEN}${C_BOLD}${LED_TYPE}${C_RESET}  ${C_DIM}(WS2812B / NeoPixel)${C_RESET}
    ${C_DIM}colorOrder${C_RESET}  = ${C_GREEN}${C_BOLD}${COLOR_ORDER}${C_RESET}
    ${C_DIM}dataSpeed${C_RESET}   = ${C_GREEN}${C_BOLD}${DATA_SPEED}${C_RESET}
$(rainbow_line 64)
BANNER
confirm "Press <enter> to begin, or Ctrl-C to abort: "

# ---- Step 1: power on the unit ----------------------------------------------

step 1 "Power on the Pixelblaze (and force setup mode if needed).

  • Plug in USB power. The board boots in ~10 seconds.
  • A fresh, never-configured unit will automatically enter 'setup
    mode' on first boot and start advertising the open AP
    'pixelblaze_XXXXXX' within ~60 seconds.
  • A previously-configured unit will instead try to rejoin its old
    network. To force it into setup mode, ${C_BOLD}press and hold the
    onboard button for ~3.5 seconds${C_RESET} after it has booted.
    (V3 only — the 5-second procedure in older docs is for V2.)
  • Short button presses cycle patterns — don't tap the button if you
    just want to provision; only the long-hold reaches setup mode.
  • Power on ONE unit at a time. With multiple up at once you'll see
    multiple pixelblaze_* SSIDs and have no way to tell them apart
    short of reading hex suffixes off the boards."

confirm "Press <enter> once the unit is powered on: "

# ---- Step 2: connect this Mac to the unit's AP ------------------------------

step 2 "Connect this Mac to the unit's setup AP.

  • Open the macOS WiFi menu (top-right) and join 'pixelblaze_XXXXXX'.
  • The XXXXXX suffix is the last 6 hex chars of the unit's MAC, so
    every unit gets a unique SSID.
  • A captive-portal window will probably pop up. You can either keep
    it open (it lands on the unit's web UI — you'll use it to enter
    WiFi creds in a later step) or close it and we'll open a fresh
    browser tab in a moment. Either works. Just do NOT click 'Cancel'
    — that disconnects you from the AP.
  • If macOS keeps yanking you back to ${HOME_SSID}, turn off auto-join
    on it (System Settings → WiFi → Details on ${HOME_SSID})."

confirm "Press <enter> once you're connected to the unit's AP: "

# Try to read the SSID we're actually on. We use this for two things:
#   (a) record the AP SSID in provisioned.json
#   (b) sanity-check — if we're still on the home network, the next
#       phase (HTTP ping to 192.168.4.1) will time out anyway, but a
#       clear up-front warning saves the user 3 seconds and confusion.
AP_SSID="$(get_current_ssid 2>/dev/null || true)"
if [[ -n "$AP_SSID" ]]; then
  log "current SSID: $AP_SSID"
  case "$AP_SSID" in
    pixelblaze_*) ok "on Pixelblaze AP: $AP_SSID" ;;
    *)
      echo
      warn "current SSID is '$AP_SSID' — not a pixelblaze_* AP."
      echo "  The AP-reachability check below will fail if you're not on the unit's AP."
      read -r -p "${C_BOLD}${C_YELLOW}Continue anyway? [y/N]: ${C_RESET}" yn
      [[ "$yn" =~ ^[yY]$ ]] || { log "aborted at SSID check"; exit 1; }
      ;;
  esac
else
  # Common when networksetup isn't available (non-macOS) or the WiFi
  # interface couldn't be identified. Don't block — the curl ping below
  # is the real authority on whether we can reach the unit.
  log "current SSID: (could not auto-detect — relying on AP ping below)"
fi

# ---- Step 3: name this unit -------------------------------------------------

# Now that we've joined the unit's AP, the user can see which physical unit
# we're talking to (by the AP suffix) and pick a meaningful name. Default
# is the next pb-NN in sequence; user can type anything else.
# Skipped when --name was passed on the CLI — that's an explicit override.
if [[ -n "$DEVICE_NAME" ]]; then
  ok "using --name from CLI: $DEVICE_NAME"
else
  default_name="$(pick_default_name)"

  step 3 "Name this unit.

  • You're connected to: ${C_GREEN}${AP_SSID:-<AP unknown>}${C_RESET}
  • Pick something friendlier than that hex suffix — for example
    'kitchen-1', 'living-room', or 'front-window'. The name shows up
    in the Pixelblaze discovery list and inside your patterns.
  • Press <enter> to accept the default '${C_GREEN}${default_name}${C_RESET}'."

  # Bold-yellow prompt to match the other confirm() calls. The default goes
  # in [brackets] per Unix convention; empty input means accept the default.
  read -r -p "${C_BOLD}${C_YELLOW}Name for this unit [${default_name}]: ${C_RESET}" entered_name
  DEVICE_NAME="${entered_name:-$default_name}"
fi

log "Provisioning: name=$DEVICE_NAME count=$PIXEL_COUNT ledType=$LED_TYPE colorOrder=$COLOR_ORDER apSsid=${AP_SSID:-?}"

# ---- Pre-flight: are we actually on the Pixelblaze AP? ----------------------

# Plain HTTP GET to the AP IP. The Pixelblaze web UI lives there. 3s timeout
# is plenty — if we're not on its network at all, we want to fail fast rather
# than hang on a TCP retry.
if ! curl -sf -m 3 "http://${AP_IP}/" -o /dev/null; then
  err "cannot reach ${AP_IP}. Are you on the Pixelblaze's AP?"
  echo "  Open the macOS WiFi menu and join the SSID starting with 'pixelblaze_'." >&2
  log "ERROR: cannot reach ${AP_IP}"
  exit 1
fi
ok "AP reachable at ${AP_IP}"
log "AP reachable at ${AP_IP}"

# ---- Phase 1: push config over WebSocket -----------------------------------

# Values are passed into Python via env vars so we don't have to worry about
# shell quoting/escaping inside the heredoc.
export PB_AP_IP="$AP_IP"
export PB_NAME="$DEVICE_NAME"
export PB_COUNT="$PIXEL_COUNT"
export PB_LED_TYPE="$LED_TYPE"
export PB_DATA_SPEED="$DATA_SPEED"
export PB_COLOR_ORDER="$COLOR_ORDER"

# `$PYTHON - <<'PY' ... PY` runs the heredoc as a script in our venv (which
# is where pixelblaze-client lives). Quoting 'PY' so nothing in the body
# gets shell-expanded. Pipe to `tee -a` so output also lands in the log.
"$PYTHON" - <<'PY' 2>&1 | tee -a "$LOG_FILE"
import json, os, sys
from pixelblaze import Pixelblaze

ip          = os.environ["PB_AP_IP"]
name        = os.environ["PB_NAME"]
count       = int(os.environ["PB_COUNT"])
ledType     = int(os.environ["PB_LED_TYPE"])
speed       = int(os.environ["PB_DATA_SPEED"])
colorOrder  = os.environ["PB_COLOR_ORDER"]

# Pixelblaze() opens the WebSocket to ws://<ip>:81 internally.
pb = Pixelblaze(ip)

# Bundle every setting into one wsSendJson call with save=true. The firmware
# accepts arbitrary combinations of keys, so this is a single atomic flash
# write instead of N separate ones (which would also wear flash faster).
#
# Keys verified against pixelblaze-client source (pixelblaze/pixelblaze.py):
#   setLedType     -> "ledType"     (int, see ledTypes enum)
#   setDataSpeed   -> "dataSpeed"   (int, Hz)
#   setPixelCount  -> "pixelCount"  (int)
#   setColorOrder  -> "colorOrder"  (string: "RGB", "GRB", "BGR", ...)
#   setDeviceName  -> "name"        (string)
#   setDiscovery   -> "discoveryEnable" (bool)
#   "save" (bool) is in the firmware's documented example messages and
#   instructs the unit to persist to flash on receipt.
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

# Read the config back so we can verify the values landed. getConfigSettings
# returns a dict with the live state straight from the unit. (NB: earlier
# versions of pixelblaze-client called this getHardwareConfig — the name
# changed; we use getConfigSettings for current versions.)
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

# Hard-fail if any of the critical values disagree with what we asked for.
# Better to stop now than write a misleading row to provisioned.json.
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
  err "WebSocket config push failed (rc=$PY_RC). See $LOG_FILE."
  log "ERROR: WebSocket config push failed (rc=$PY_RC)"
  exit 1
fi
ok "WebSocket config push OK"
log "WebSocket config push OK"

# ---- Phase 2: hand off to the browser for WiFi credentials ------------------

# We deliberately do everything WiFi-related by hand from the browser. Past
# attempts to drive WiFi setup programmatically (over WebSocket or by
# reverse-engineering the web UI form) have been buggy/inconsistent across
# firmware versions, so we just open the browser, name the SSID and the
# field labels, and let the human do the typing.
cat <<MSG

$(rainbow_line 64 "─")
${C_BOLD}Now type the home WiFi credentials into the browser.${C_RESET}

  ${C_CYAN}1.${C_RESET} A tab is opening at ${C_BLUE}http://${AP_IP}${C_RESET} — that's the unit's
     onboard web UI. ${C_DIM}(If a captive-portal popup also opened back in
     Step 2, you can use that window instead — same page.)${C_RESET}
  ${C_CYAN}2.${C_RESET} Find the WiFi setup form. Manually enter:

        ${C_DIM}SSID:${C_RESET}     ${C_GREEN}${C_BOLD}${HOME_SSID}${C_RESET}
        ${C_DIM}Password:${C_RESET} ${C_BOLD}(type it in by hand)${C_RESET}

  ${C_CYAN}3.${C_RESET} Save. The unit reboots and tries to join ${C_GREEN}${HOME_SSID}${C_RESET}.
     The ${C_DIM}pixelblaze_xxxxxx${C_RESET} AP should disappear within ~30s.

When the AP is gone, reconnect this Mac to ${C_GREEN}${HOME_SSID}${C_RESET}. The unit
should show up at ${C_BLUE}http://discover.electromage.com${C_RESET} (or via the local
PixelblazeEnumerator) under the name ${C_GREEN}${C_BOLD}${DEVICE_NAME}${C_RESET}.
$(rainbow_line 64 "─")

MSG

# `open` is macOS-specific. On Linux this would be `xdg-open`. We `|| true`
# because failing to open a browser shouldn't abort provisioning — the user
# can navigate to the URL manually.
if command -v open >/dev/null 2>&1; then
  open "http://${AP_IP}/" || true
fi

# Block until the user confirms they finished the WiFi step. Without this
# pause, we'd write provisioned.json before WiFi was actually saved, which
# would be misleading if WiFi save failed. This is a manual checkpoint.
confirm "Press <enter> AFTER you've saved WiFi creds in the web UI: "

# ---- Phase 3: append entry to provisioned.json ------------------------------

# Atomic write: build the new list, write to a .tmp file, rename. If the
# script gets killed mid-write, the original file is still intact.
export PB_MAP_FILE="$MAP_FILE"
export PB_AP_SSID="$AP_SSID"
# Phase 3 doesn't strictly need the venv (no pixelblaze import), but we use
# it for consistency — same Python everywhere in the script.
"$PYTHON" - <<'PY' | tee -a "$LOG_FILE"
import json, os, time
from pathlib import Path

map_file = Path(os.environ["PB_MAP_FILE"])
entry = {
    "name":       os.environ["PB_NAME"],
    "pixelCount": int(os.environ["PB_COUNT"]),
    "ledType":   int(os.environ["PB_LED_TYPE"]),
    "timestamp":  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    # AP SSID is auto-captured from the Mac's current WiFi connection in
    # Step 2 (may be empty on non-macOS or if detection failed). homeIp is
    # left blank — populating it would require a follow-up enumerator pass
    # after this script exits and the user reconnects to the home network.
    "apSsid":     os.environ.get("PB_AP_SSID", ""),
    "homeIp":     "",
}

if map_file.exists():
    text = map_file.read_text().strip()
    data = json.loads(text) if text else []
else:
    data = []

data.append(entry)

tmp = map_file.with_suffix(map_file.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
tmp.replace(map_file)

print(f"appended to {map_file.name}: {entry['name']}")
PY

log "Done: $DEVICE_NAME"

# Rainbow finale. The actual record-of-truth is the log + provisioned.json;
# this is just for the human's eyeballs.
echo
rainbow_line 64; echo
printf '  %s%s%s provisioned!%s  %s\n' "$C_BOLD" "$C_GREEN" "$DEVICE_NAME" "$C_RESET" "$(rainbow "all done")"
echo
rainbow_line 64; echo
echo
