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

# ---- Logging helper ---------------------------------------------------------

# Every non-trivial line goes to both stdout and the log file, prefixed with
# a UTC timestamp. The log is the trace you'll want when something fails.
log() {
  local ts; ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '%s  %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

# ---- Interactive helpers ----------------------------------------------------

# Print a numbered step header followed by a description. Visual separator
# so the human can find their place easily when the screen scrolls.
step() {
  local n="$1"; shift
  echo
  printf '── Step %s ──────────────────────────────────────────\n' "$n"
  printf '%s\n' "$*"
  echo
}

# Block until the user presses enter. Use this for "I've done the physical
# step you asked for" handoffs. Ctrl-C aborts as normal.
confirm() {
  local prompt="${1:-Press <enter> when ready, or Ctrl-C to abort: }"
  read -r -p "$prompt" _
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

# ---- Auto-pick a name if --name was not supplied ----------------------------

# Strategy: look at provisioned.json, find the highest existing index that
# matches NAME_PREFIX, add 1. On a fresh map file, start at 1.
if [[ -z "$DEVICE_NAME" ]]; then
  if [[ -f "$MAP_FILE" ]]; then
    next_idx="$(python3 - "$MAP_FILE" "$NAME_PREFIX" <<'PY'
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
  else
    next_idx=1
  fi
  # Zero-pad to 2 digits (pb-01, pb-02, ...). Bump the width if you ever
  # provision more than 99 units.
  printf -v DEVICE_NAME '%s%02d' "$NAME_PREFIX" "$next_idx"
fi

log "Starting provision: name=$DEVICE_NAME count=$PIXEL_COUNT ledType=$LED_TYPE colorOrder=$COLOR_ORDER"

# ---- Pre-flight: pixelblaze-client installed? -------------------------------

# Done first so we fail fast — no point walking the user through power-on
# if Python can't drive the WebSocket. Don't auto-install: surprise pip
# installs into someone's global site-packages is rude.
if ! python3 -c 'import pixelblaze' 2>/dev/null; then
  echo "Missing dependency: pixelblaze-client" >&2
  echo "Install with:  pip3 install pixelblaze-client" >&2
  exit 1
fi

# ---- Welcome banner ---------------------------------------------------------

# Show the user what's about to happen and what values we'll write, BEFORE
# they take any physical action. Last chance to Ctrl-C if anything is wrong.
cat <<BANNER

================================================================
  Pixelblaze provisioning — single unit
================================================================
  This script will walk you through:
    1. Power on the Pixelblaze
    2. Connect this Mac to the unit's setup AP
    3. Push LED config + name over WebSocket (automated)
    4. Use the unit's web UI to enter home WiFi creds
    5. Record the unit in provisioned.json (automated)

  Values to write on this unit:
    name        = ${DEVICE_NAME}
    pixelCount  = ${PIXEL_COUNT}
    ledType     = ${LED_TYPE}  (WS2812B / NeoPixel)
    colorOrder  = ${COLOR_ORDER}
    dataSpeed   = ${DATA_SPEED}
================================================================
BANNER
confirm "Press <enter> to begin, or Ctrl-C to abort: "

# ---- Step 1: power on the unit ----------------------------------------------

step 1 "Power on the Pixelblaze.

  • Plug in USB power. The board boots in ~10 seconds.
  • Within ~60 seconds, the unit advertises its setup AP as
    'pixelblaze_XXXXXX' (open network — no password).
  • Power on ONE unit at a time. With multiple units up at once you'll
    see multiple pixelblaze_* SSIDs and have no way to tell them apart
    short of reading hex suffixes off the boards."

confirm "Press <enter> once the unit is powered on: "

# ---- Step 2: connect this Mac to the unit's AP ------------------------------

step 2 "Connect this Mac to the unit's setup AP.

  • Open the macOS WiFi menu (top-right) and join 'pixelblaze_XXXXXX'.
  • The XXXXXX suffix is the last 6 hex chars of the unit's MAC, so
    every unit gets a unique SSID.
  • If a captive-portal window pops up: just CLOSE it. Do NOT click
    'Cancel' — that disconnects you from the AP.
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
    pixelblaze_*) ;;  # looks right — fall through
    *)
      echo
      echo "WARNING: current SSID is '$AP_SSID', which doesn't look like a"
      echo "Pixelblaze AP (expected pixelblaze_XXXXXX). The AP-reachability"
      echo "check below will fail if you're not actually on the unit's AP."
      read -r -p "Continue anyway? [y/N]: " yn
      [[ "$yn" =~ ^[yY]$ ]] || { log "aborted at SSID check"; exit 1; }
      ;;
  esac
else
  # Common when networksetup isn't available (non-macOS) or the WiFi
  # interface couldn't be identified. Don't block — the curl ping below
  # is the real authority on whether we can reach the unit.
  log "current SSID: (could not auto-detect — relying on AP ping below)"
fi

# ---- Pre-flight: are we actually on the Pixelblaze AP? ----------------------

# Plain HTTP GET to the AP IP. The Pixelblaze web UI lives there. 3s timeout
# is plenty — if we're not on its network at all, we want to fail fast rather
# than hang on a TCP retry.
if ! curl -sf -m 3 "http://${AP_IP}/" -o /dev/null; then
  log "ERROR: cannot reach ${AP_IP}. Are you on the Pixelblaze's AP?"
  echo "Open the macOS WiFi menu and join the SSID starting with 'pixelblaze_'." >&2
  exit 1
fi
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

# `python3 - <<'PY' ... PY` runs the heredoc as a script. Quoting 'PY' so
# nothing in the body gets shell-expanded.
# Pipe to `tee -a` so the Python output also lands in the log file.
python3 - <<'PY' 2>&1 | tee -a "$LOG_FILE"
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

# Read the config back so we can verify the values landed. getHardwareConfig
# returns a dict with the live state straight from the unit.
hw = pb.getHardwareConfig() or {}
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
  log "ERROR: WebSocket config push failed (rc=$PY_RC). See $LOG_FILE."
  exit 1
fi
log "WebSocket config push OK"

# ---- Phase 2: hand off to the web UI for WiFi credentials -------------------

# We could try to reverse-engineer the WiFi save endpoint from browser dev
# tools, but instructions.md says not to guess. The web UI is on the unit
# itself and works fine — this is the supported path.
cat <<MSG

---------------------------------------------------------------------
Now finish the WiFi step in the unit's web UI.

  1. The browser will open http://${AP_IP}
  2. Click the WiFi tab
  3. Choose "Existing Network", then enter:
        SSID:     ${HOME_SSID}
        Password: (the home WiFi password — see instructions.md)
  4. Click Save. The unit reboots and tries to join ${HOME_SSID}.
  5. The pixelblaze_xxxxxx AP should disappear within ~30s.

When the AP is gone, reconnect this Mac to ${HOME_SSID}. The unit
should show up at http://discover.electromage.com (or via the local
PixelblazeEnumerator) under the name "${DEVICE_NAME}".
---------------------------------------------------------------------

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
read -r -p "Press <enter> AFTER you've saved WiFi creds in the web UI: " _

# ---- Phase 3: append entry to provisioned.json ------------------------------

# Atomic write: build the new list, write to a .tmp file, rename. If the
# script gets killed mid-write, the original file is still intact.
export PB_MAP_FILE="$MAP_FILE"
export PB_AP_SSID="$AP_SSID"
python3 - <<'PY' | tee -a "$LOG_FILE"
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
