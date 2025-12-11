#!/usr/bin/env bash
# Rev 5

set -euo pipefail

CONFIG="/opt/etc/unattended_update.conf"

if [[ ! -f "$CONFIG" ]]; then
  echo "No configuration file present at $CONFIG"
  exit 0
fi

source "$CONFIG"

if [[ "${set_debug:-disabled}" == "enabled" ]]; then
  set -x
fi

for cmd in vcgencmd curl hostname printf jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command '$cmd' not found in PATH"
    exit 1
  fi
done

: "${pushbullet_token:?pushbullet_token must be set in $CONFIG}"

raw_throttled="$(vcgencmd get_throttled 2>/dev/null || true)"   # e.g., "throttled=0x50005"
throttled_hex="${raw_throttled#throttled=}"
throttled_hex="${throttled_hex,,}"  # lower-case

if [[ -n "${throttled_hex}" ]]; then
  throttled_dec=$(( 16#${throttled_hex#0x} ))
else
  throttled_dec=0
fi

temperature_raw="$(vcgencmd measure_temp 2>/dev/null || true)"   # "temp=54.8'C"
temperature="${temperature_raw#temp=}"
voltage_raw="$(vcgencmd measure_volts 2>/dev/null || true)"      # "volt=0.86V"
voltage="${voltage_raw#volt=}"

host="$(hostname 2>/dev/null || cat /etc/hostname || echo "unknown-host")"

has_bit() {
  local value="$1" bit="$2"
  (( (value & (1 << bit)) != 0 ))
}

declare -a msgs

has_bit "$throttled_dec" 16 && msgs+=("Under-voltage has occurred (voltage: ${voltage:-n/a})")
has_bit "$throttled_dec" 17 && msgs+=("ARM frequency capping has occurred")
has_bit "$throttled_dec" 18 && msgs+=("Throttling has occurred")
has_bit "$throttled_dec" 19 && msgs+=("Soft temperature limit has occurred (temperature: ${temperature:-n/a})")

has_bit "$throttled_dec" 0 && msgs+=("Under-voltage detected NOW (voltage: ${voltage:-n/a})")
has_bit "$throttled_dec" 1 && msgs+=("ARM frequency capping in effect NOW")
has_bit "$throttled_dec" 2 && msgs+=("Throttling in effect NOW")
has_bit "$throttled_dec" 3 && msgs+=("Soft temperature limit in effect NOW (temperature: ${temperature:-n/a})")

if [[ ${#msgs[@]} -eq 0 ]]; then
  exit 0
fi

status_summary=$(
  printf "vcgencmd get_throttled: %s\n" "${throttled_hex:-0x0}"
  printf "Voltage: %s | Temperature: %s\n" "${voltage:-n/a}" "${temperature:-n/a}"
  printf "Conditions:\n"
  for m in "${msgs[@]}"; do
    printf " - %s\n" "$m"
  done
)

pushbullet_url="https://api.pushbullet.com/v2/pushes"
title="Throttling/Power Alert on ${host}"

if [[ -n "${pushbullet_device_id:-}" ]]; then
  json_payload=$(
    jq -n --arg t "$title" --arg b "$status_summary" --arg d "$pushbullet_device_id" \
      '{type:"note", title:$t, body:$b, device_iden:$d}'
  )
else
  json_payload=$(
    jq -n --arg t "$title" --arg b "$status_summary" \
      '{type:"note", title:$t, body:$b}'
  )
fi

tmp_resp="$(mktemp /tmp/pb_resp.XXXXXX)"
tmp_hdrs="$(mktemp /tmp/pb_hdrs.XXXXXX)"

xtrace_was_on=false
if [[ "${-}" == *x* ]]; then
  xtrace_was_on=true
  set +x
fi

http_status=$(
  curl -sS -D "$tmp_hdrs" -o "$tmp_resp" -w "%{http_code}" \
    -H "Access-Token: ${pushbullet_token}" \
    -H "Content-Type: application/json" \
    -X POST -d "$json_payload" \
    "$pushbullet_url"
)

if $xtrace_was_on; then
  set -x
fi

if [[ "$http_status" != "200" ]]; then
  echo "Pushbullet notification failed with HTTP $http_status"
  # Pretty-print error JSON if possible
  if jq . "$tmp_resp" >/dev/null 2>&1; then
    jq . "$tmp_resp"
  else
    sed -n '1,200p' "$tmp_resp" || true
  fi
  echo "Rate-limit (if provided):"
  grep -i '^X-Ratelimit-' "$tmp_hdrs" || true
  rm -f "$tmp_resp" "$tmp_hdrs"
  exit 1
else
  echo "Pushbullet notification sent for ${host} (${http_status})"
  # Optional: show ratelimit headers for visibility
  grep -i '^X-Ratelimit-' "$tmp_hdrs" || true
  rm -f "$tmp_resp" "$tmp_hdrs"
fi

if has_bit "$throttled_dec" 0 || has_bit "$throttled_dec" 1 || has_bit "$throttled_dec" 2 || has_bit "$throttled_dec" 3; then
  exit 2
fi

if [[ "${set_debug:-disabled}" == "enabled" ]]; then
  set +x
fi
