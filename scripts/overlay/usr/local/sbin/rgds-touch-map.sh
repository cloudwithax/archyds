#!/usr/bin/env bash
# RG DS dual-screen touch mapping — first-boot system-level config.
# Writes kcminputrc (touch → output binding) and kwinoutputconfig.json
# (display arrangement) for the alarm user and skel template.
# Called from rgds-firstboot.sh step [6/7].
set -euo pipefail

LOG_FILE="/var/log/rgds-firstboot.log"

log() { echo "[rgds-touch-map] $*" | tee -a "$LOG_FILE"; }

ALARM_HOME="/home/alarm"
ALARM_CONFIG="${ALARM_HOME}/.config"
SKEL_CONFIG="/etc/skel/.config"

# --- kcminputrc: only bind one touch IC at a time (dual breaks input) ---
# KWin uses bracket-separated INI groups: [Libinput][vendor][product][name]
KCMINPUTC_CONTENT='[Libinput][1046][48879][gt9xx-0]
Calibration=1 0 0 0 1 0
Enabled=true
OutputName=DSI-2
'

write_kcminputrc() {
  local dir="$1"
  mkdir -p "$dir"
  # Only write if not already present with correct group format
  if [[ -f "$dir/kcminputrc" ]] && grep -qE '^\[Libinput\]\[1046\]\[48879\]\[gt9xx-0\]' "$dir/kcminputrc" 2>/dev/null; then
    log "kcminputrc already configured in $dir"
    return 0
  fi
  echo "$KCMINPUTC_CONTENT" > "$dir/kcminputrc"
  chown alarm:alarm "$dir/kcminputrc" 2>/dev/null || true
  log "kcminputrc written to $dir"
}

# --- kwinoutputconfig.json: DSI-1 top (0,0), DSI-2 bottom (0,480) primary ---
KWIN_OUTPUT_CONTENT='[
  {
    "data": [
      {
        "autoRotation": "InTabletMode",
        "brightness": 0.78,
        "colorPowerTradeoff": "PreferEfficiency",
        "colorProfileSource": "sRGB",
        "connectorName": "DSI-1",
        "edrPolicy": "always",
        "highDynamicRange": false,
        "iccProfilePath": "",
        "overscan": 0,
        "rgbRange": "automatic",
        "scale": 1,
        "sdrBrightness": 0.78,
        "sdrGamutWideness": 0,
        "writableSize": { "width": 640, "height": 480 }
      },
      {
        "autoRotation": "InTabletMode",
        "brightness": 0.78,
        "colorPowerTradeoff": "PreferEfficiency",
        "colorProfileSource": "sRGB",
        "connectorName": "DSI-2",
        "edrPolicy": "always",
        "highDynamicRange": false,
        "iccProfilePath": "",
        "overscan": 0,
        "rgbRange": "automatic",
        "scale": 1,
        "sdrBrightness": 0.78,
        "sdrGamutWideness": 0,
        "writableSize": { "width": 640, "height": 480 }
      }
    ]
  },
  {
    "data": [
      {
        "enabled": true,
        "outputIndex": 0,
        "position": { "x": 0, "y": 0 },
        "priority": 2,
        "replicationSource": ""
      },
      {
        "enabled": true,
        "outputIndex": 1,
        "position": { "x": 0, "y": 480 },
        "priority": 1,
        "replicationSource": ""
      }
    ]
  }
]
'

write_kwinoutput() {
  local dir="$1"
  mkdir -p "$dir"
  if [[ -f "$dir/kwinoutputconfig.json" ]]; then
    log "kwinoutputconfig.json already exists in $dir"
    return 0
  fi
  echo "$KWIN_OUTPUT_CONTENT" > "$dir/kwinoutputconfig.json"
  chown alarm:alarm "$dir/kwinoutputconfig.json" 2>/dev/null || true
  log "kwinoutputconfig.json written to $dir"
}

# --- main ---
write_kcminputrc "$ALARM_CONFIG"
write_kcminputrc "$SKEL_CONFIG"
write_kwinoutput "$ALARM_CONFIG"
write_kwinoutput "$SKEL_CONFIG"

log "Touch mapping configured (DSI-1=top, DSI-2=bottom)"
exit 0
