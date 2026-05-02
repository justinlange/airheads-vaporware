# Pixelblaze Provisioning

Two sections below: the brief to paste into Claude Code, and the human runbook for what to do at the keyboard while it runs.

---

## Part 1: Paste this into Claude Code

### Goal
Automate provisioning of Pixelblaze V3 units. Per unit, the flow is:

1. Connect this machine to the Pixelblaze's setup AP (SSID matches `pixelblaze_XXXXXX`, open network)
2. Over the WebSocket API at `ws://192.168.4.1:81`, push:
   - Home WiFi credentials: SSID `badgirlsclub`, password `wooisthepresident`
   - Enable discovery service
   - LED type = WS2812/NeoPixel (`ledType: 1`)
   - Pixel count = 68
   - A custom device name (see "Naming" below)
   - Save all to flash
3. Wait for the unit to leave AP mode and join `badgirlsclub`
4. Reconnect this machine to `badgirlsclub`
5. Discover the unit on the home network (UDP enumerator preferred) and verify settings stuck

### Detect the OS first
Before doing anything else, detect the OS and WiFi interface programmatically:

```bash
uname -a
# macOS: also run
sw_vers
networksetup -listallhardwareports | grep -A1 -i wi-fi
# Linux: also run
nmcli -t -f DEVICE,TYPE device | grep wifi
# Windows: also run (in PowerShell)
Get-NetAdapter | Where-Object {$_.Name -like '*Wi-Fi*' -or $_.InterfaceDescription -like '*Wireless*'}
```

Pick the right WiFi command set based on what you find, and tell the user what you detected before proceeding.

### Naming convention
Each unit gets a custom name. Default scheme: `pb-<NN>` where NN is a zero-padded sequence (`pb-01`, `pb-02`, ...). Ask the user at start of run:
- Starting number for the sequence (default: 1)
- Optional prefix override (default: `pb-`)
- Whether to also store a mapping file (`provisioned.json`) recording: assigned name, original AP SSID, MAC if available, home-network IP after join, timestamp

Always write the mapping file. It's the only record of which physical unit got which name.

### Key technical facts (don't re-research these)

- **AP-mode IP is `192.168.4.1`.** The user's original notes said `192.168.4.44` — that was a typo.
- **WebSocket API:** `ws://<ip>:81`, JSON messages. Examples:
  - `{"pixelCount": 68, "save": true}`
  - `{"ledType": 1, "dataSpeed": 2000000, "save": true}`
  - `{"name": "pb-01"}`
- **Use `pixelblaze-client`** (`pip install pixelblaze-client`). Wraps the websocket. Methods: `setPixelCount`, `setLedType`, `setDiscovery`, `setDeviceName`. Source: https://github.com/zranger1/pixelblaze-client — read it to confirm method signatures and to find the WiFi-credential keys.
- **WiFi credential push** is NOT exposed as a clean named method in the high-level wrapper. You'll need either `wsSendJson` directly, or to inspect what the web UI at `192.168.4.1` POSTs. **Verify the exact JSON keys before sending — don't guess.** Likely shape is something like `{"ssid": "...", "psk": "...", "save": true}` but confirm.
- **`PixelblazeEnumerator`** in the same library does local UDP discovery on the home network. Use this over the cloud `discover.electromage.com` URL.
- **Followers caveat:** pixel count can't be changed on a unit with followers, and follower-mode units reject most config changes. Fresh units are fine. If re-provisioning, un-follow first.

### OS-level WiFi switching reference

After detecting OS, use the matching commands:

- **macOS:** `networksetup -setairportnetwork <iface> <ssid> [password]`. Interface usually `en0` or `en1`. Captive-portal popups can interrupt — may need `sudo /usr/libexec/airportd <iface> disassociate` between switches. macOS may also auto-rejoin a known network; turn off auto-join on `badgirlsclub` temporarily if it keeps stealing the connection back.
- **Linux:** `nmcli device wifi rescan` then `nmcli device wifi connect <ssid> [password <pw>]`.
- **Windows:** `netsh wlan connect name=<profile>` requires a pre-saved profile. Create one with `netsh wlan add profile filename=...` or generate XML inline.

Scanning for `pixelblaze_*` SSIDs:
- macOS recent versions: `wdutil info` and `system_profiler SPAirPortDataType` (the old `airport -s` is deprecated). May need a third-party tool or to prompt the user to read off the SSID.
- Linux: `nmcli -t -f SSID device wifi list`
- Windows: `netsh wlan show networks`

### Questions to ask the user at start of run

1. Confirm OS detection result
2. One unit at a time, or how many in this batch?
3. Are units fresh, or being re-provisioned (might have follower config)?
4. Naming: starting number and prefix (defaults `1` and `pb-`)
5. Custom pixel count for any unit, or all 68?

### Build approach

- **Start with one unit end-to-end before looping.** Manual AP join the first time if needed; get the WebSocket-config part rock solid first.
- Then automate WiFi switching around it.
- Then add the loop.
- **Log everything to a file**, not just stdout: WebSocket request/response, timing of AP appearing/disappearing, reconnect attempts, enumerator results. This process is flaky in ways you'll want the trace for.
- Retries with timeouts at every network boundary. Reasonable timeouts: AP appears within 60s of power-on, AP disappears within 30s of WiFi save, unit shows on home network within 90s of AP disappearing.

### Per-unit success criteria

- WebSocket connects on `192.168.4.1:81`
- Config writes return without error
- AP disappears within 60s of save
- Unit appears on home network via enumerator within 90s
- `getHardwareConfig` from home network confirms `ledType=1`, `pixelCount=68`, name matches assignment
- Entry written to `provisioned.json`

### Don't

- Don't use `discover.electromage.com` for local discovery — use UDP `PixelblazeEnumerator`.
- Don't skip `save: true` — values revert on reboot.
- Don't guess the WiFi credential JSON shape. Read the library source.
- Don't proceed past a failed unit silently. Stop, log, ask the user.

---

## Part 2: Human runbook (what you do at the keyboard)

### Before starting
- Have the units, power supplies, and any LED strips/loads in a known state. Power one unit at a time unless the agent says otherwise.
- Close anything that auto-grabs WiFi (corporate VPN clients, location-aware WiFi managers).
- macOS: System Settings → WiFi → Details on `badgirlsclub` → turn OFF "Auto-Join" temporarily. Turn it back on after the run. Without this, macOS will yank you off the Pixelblaze AP mid-config.
- Have the password handy: `wooisthepresident` (the agent has it, but you'll need it for any manual recovery).

### During the run
- Power on one unit. Wait ~60s for its `pixelblaze_XXXXXX` AP to appear.
- Tell the agent it's powered on; let it drive.
- If macOS pops a captive-portal window when joining the Pixelblaze AP, dismiss it (don't click "Cancel" — that disconnects). Just close the window.
- If the agent asks you to confirm the SSID it found, double-check it matches the unit you just powered on (the suffix is per-device).
- After each unit, agent will write to `provisioned.json`. Glance at it to confirm the name/IP look right before powering the next unit.

### If it gets stuck
- Most common failure: machine reconnected to `badgirlsclub` instead of staying on the Pixelblaze AP. Fix: turn off `badgirlsclub` auto-join (see above), have the agent retry.
- Second most common: WiFi creds didn't save and the unit comes back up still in AP mode. Fix: agent should detect this (AP didn't disappear) and retry the save once before flagging.
- If a unit's AP never appears: hold its button 5+ seconds to force WiFi reset, or power-cycle. If that fails twice, set it aside and move on — flag the unit physically.

### After the run
- Re-enable `badgirlsclub` auto-join.
- Open `http://discover.electromage.com` from any device on the home network — should show all provisioned units with their assigned names. Cross-check against `provisioned.json`.
- Pick one unit at random, hit its IP, confirm LED type and count in Settings.

### Note on followers
None of these units should be in follower mode at provisioning. If you've previously paired any of these as followers, take them out of follower mode FIRST (via the leader's UI), then re-provision. The agent will refuse to set pixel count on a follower unit and will tell you which one.