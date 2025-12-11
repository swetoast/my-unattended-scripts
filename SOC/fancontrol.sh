#!/usr/bin/env bash
# Raspberry Pi fan controller with EMA smoothing, hysteresis, dwell times, and quiet-hours policy.
# Active-low wiring assumed (drive pin HIGH = OFF, drive LOW = ON).
# Requires: bash, vcgencmd, pinctrl, awk, grep, logger, flock, date

set -Eeuo pipefail

# ---------- Configuration ----------
# Temperature bands (°C) with hysteresis:
HIGH_ON=66            # enter HIGH when EMA >= 66°C
HIGH_OFF=60           # leave HIGH when EMA <= 60°C
LOW_ON=56             # enter LOW when EMA >= 56°C (if not already HIGH)
LOW_OFF=52            # turn OFF when EMA <= 52°C

GPIO_PIN=45           # GPIO pin controlling the fan (board-specific)
SPIN_TIME=180         # post-change dwell seconds
HIGH_SPEED_SPIN_TIME=600

# Quiet hours (24h clock); hours are inclusive at start, exclusive at end
QUIET_HOURS_START=22  # from 22:00…
QUIET_HOURS_END=8     # …until 08:00
QUIET_CAP="low"       # during quiet: "off" or "low"
QUIET_ALLOW_OVERHEAT_OVERRIDE=true

SLEEP_DURATION=1      # main loop sleep (seconds)
EMA_ALPHA=0.25        # EMA smoothing factor (0.2–0.3 recommended)
MIN_DWELL_ON=120      # min seconds between turning ON and then turning OFF
MIN_DWELL_CHANGE=60   # min seconds between any speed changes

# ---------- Globals ----------
CURRENT_STATE="off"   # "off" | "low" | "high"
EMA_TEMP=""           # initialized on first sample
LAST_CHANGE_EPOCH=0
LAST_ON_EPOCH=0

# ---------- Helpers ----------
now_epoch() { date +%s; }

log() { logger -t fanctl "$*"; echo "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

# Reads temperature like: 48.0 (°C) from vcgencmd output "temp=48.0'C"
get_temp() {
  vcgencmd measure_temp | awk -F "[=']" '{print $2}'
}

# Overheat if throttled flags are set (past or current)
check_overheat() {
  vcgencmd get_throttled | grep -qE "0x4|0x40000" && echo "overheated" || echo "normal"
}

# ---------- Fan primitives (ACTIVE-LOW: high=OFF, low=ON) ----------
fan_off() {
  pinctrl set "$GPIO_PIN" op dh   # drive pin HIGH => OFF (active-low)
  CURRENT_STATE="off"
  log "Fan OFF"
}

fan_low() {
  pinctrl set "$GPIO_PIN" op dl   # drive pin LOW  => ON (active-low)
  # If your HAT needs an alt func for 'low', add it here, e.g.: pinctrl set "$GPIO_PIN" a1
  CURRENT_STATE="low"
  log "Fan LOW"
}

fan_high() {
  pinctrl set "$GPIO_PIN" op dl   # drive pin LOW  => ON (active-low)
  # If your HAT needs an alt func for 'high', add it here, e.g.: pinctrl set "$GPIO_PIN" a2
  CURRENT_STATE="high"
  log "Fan HIGH"
}

# ---------- Policy & control ----------
can_change_state() {
  local now
  now=$(now_epoch)
  # Avoid rapid toggles
  if (( now - LAST_CHANGE_EPOCH < MIN_DWELL_CHANGE )); then
    return 1
  fi
  # Ensure we don't turn off too soon after turning on
  if [[ "$CURRENT_STATE" != "off" ]] && (( now - LAST_ON_EPOCH < MIN_DWELL_ON )); then
    return 1
  fi
  return 0
}

apply_state() {
  local target="$1"
  [[ "$target" == "$CURRENT_STATE" ]] && return 0
  can_change_state || return 0

  case "$target" in
    off)  fan_off  ;;
    low)  fan_low  ;;
    high) fan_high ;;
    *)    log "Unknown target state: $target"; return 1 ;;
  esac

  LAST_CHANGE_EPOCH=$(now_epoch)
  [[ "$CURRENT_STATE" != "off" ]] && LAST_ON_EPOCH="$LAST_CHANGE_EPOCH"

  # Post-change dwell; longer if overheated
  local spin="$SPIN_TIME"
  if [[ $(check_overheat) == "overheated" ]]; then
    spin="$HIGH_SPEED_SPIN_TIME"
  fi
  sleep "$spin" || true
}

# Decide desired state from EMA temperature with hysteresis
decide_state() {
  local t="$1"

  # Stay/go HIGH
  if awk -v x="$t" -v y="$HIGH_ON"  'BEGIN{exit !(x>=y)}'; then
    echo "high"; return
  fi
  if [[ "$CURRENT_STATE" == "high" ]] && awk -v x="$t" -v y="$HIGH_OFF" 'BEGIN{exit !(x>y)}'; then
    echo "high"; return
  fi

  # Stay/go LOW
  if awk -v x="$t" -v y="$LOW_ON" 'BEGIN{exit !(x>=y)}'; then
    echo "low"; return
  fi
  if [[ "$CURRENT_STATE" == "low" ]] && awk -v x="$t" -v y="$LOW_OFF" 'BEGIN{exit !(x>y)}'; then
    echo "low"; return
  fi

  # Otherwise OFF
  echo "off"
}

in_quiet_hours() {
  local H
  H=$(date +%-H)
  if (( H >= QUIET_HOURS_START || H < QUIET_HOURS_END )); then
    return 0
  else
    return 1
  fi
}

sleep_until_quiet_end() {
  local now end delta
  now=$(date +%s)
  if (( $(date +%-H) < QUIET_HOURS_END )); then
    end=$(date -d "$(date +%F) ${QUIET_HOURS_END}:00:00" +%s)
  else
    end=$(date -d "tomorrow ${QUIET_HOURS_END}:00:00" +%s)
  fi
  delta=$(( end - now ))
  (( delta > 0 )) && sleep "$delta"
}

cleanup() {
  # On exit, be conservative; if you prefer fail-safe ON, call fan_low instead.
  fan_off || true
}
trap cleanup EXIT INT TERM

# ---------- Single instance guard ----------
# Use /run if available, fall back to /tmp
exec 9>/run/fanctl.lock 2>/dev/null || exec 9>/tmp/fanctl.lock
flock -n 9 || { log "Already running, exiting."; exit 0; }

# ---------- Preconditions ----------
require_cmd vcgencmd
require_cmd pinctrl
require_cmd awk
require_cmd grep
require_cmd logger
require_cmd flock
require_cmd date

log "fanctl starting; active-low wiring assumed."

# ---------- Main loop ----------
while true; do
  if in_quiet_hours; then
    if [[ "$QUIET_ALLOW_OVERHEAT_OVERRIDE" == "true" ]] && [[ $(check_overheat) == "overheated" ]]; then
      apply_state "high"
      sleep "$SLEEP_DURATION"
    else
      case "$QUIET_CAP" in
        off) apply_state "off" ;;
        low) apply_state "low" ;;
        *)   apply_state "off" ;;
      esac
      sleep_until_quiet_end
    fi
    continue
  fi

  # Temperature sample + EMA smoothing
  current=$(get_temp)  # e.g., 58.2
  if [[ -z "${EMA_TEMP}" ]]; then
    EMA_TEMP="$current"
  else
    EMA_TEMP=$(awk -v a="$EMA_ALPHA" -v t="$current" -v e="$EMA_TEMP" \
      'BEGIN{printf("%.1f", a*t + (1-a)*e)}')
  fi

  # Overheat overrides everything
  if [[ $(check_overheat) == "overheated" ]]; then
    apply_state "high"
    sleep "$SLEEP_DURATION"
    continue
  fi

  target=$(decide_state "$EMA_TEMP")
  apply_state "$target"

  sleep "$SLEEP_DURATION"
done
