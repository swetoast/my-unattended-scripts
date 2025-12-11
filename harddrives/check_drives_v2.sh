#!/usr/bin/env bash
# Revision 16

set -Eeuo pipefail

# Configuration
CONFIG=${CONFIG:-/opt/etc/unattended_update.conf}

# Defaults if config is missing/partial
# (All can be overridden from /opt/etc/unattended_update.conf)

# pushbullet_token:
#   Purpose  : Access token used to authenticate against Pushbullet's API.
#   Type     : string (non-empty to enable pushing)
#   Default  : "" (empty => script prints summary to stdout instead of pushing)
#   Example  : o.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
pushbullet_token=${pushbullet_token:-""}  # REQUIRED to send pushes

# pb_channel_tag:
#   Purpose  : Send pushes to a named channel (broadcast to all channel subscribers).
#   Type     : string (lowercase tag as created in Pushbullet)
#   Default  : "" (disabled)
#   Example  : "ops-alerts"
#   Note     : Set **at most one** of pb_channel_tag / pb_target_device_iden / pb_target_email.
pb_channel_tag=${pb_channel_tag:-""}

# pb_target_device_iden:
#   Purpose  : Target a single device by its device "iden".
#   Type     : string (Pushbullet device iden)
#   Default  : "" (disabled)
#   Example  : "u1qSJddxeKwOGuGW"
#   Note     : Set **at most one** of pb_channel_tag / pb_target_device_iden / pb_target_email.
pb_target_device_iden=${pb_target_device_iden:-""}

# pb_target_email:
#   Purpose  : Target a single contact by email (sends to that user).
#   Type     : string (email address)
#   Default  : "" (disabled)
#   Example  : "alerts@example.com"
#   Note     : Set **at most one** of pb_channel_tag / pb_target_device_iden / pb_target_email.
pb_target_email=${pb_target_email:-""}

# pb_send_link:
#   Purpose  : Also send a "link" push (e.g., runbook/dashboard) after the summary note(s).
#   Type     : boolean-like (true/false)
#   Default  : false
#   Example  : true
pb_send_link=${pb_send_link:-false}

# pb_link_url:
#   Purpose  : URL used for the optional link push when pb_send_link=true.
#   Type     : string (valid URL)
#   Default  : "" (no link push unless set)
#   Example  : "https://intranet/runbooks/disk-health"
pb_link_url=${pb_link_url:-""}

# pb_chunk_size:
#   Purpose  : Maximum characters per Pushbullet note; large summaries are split into chunks.
#   Type     : integer (approximate safe size for the free plan clients)
#   Default  : 3500
#   Tradeoff : Larger chunks mean fewer pushes (good for rate limits) but risk client truncation.
pb_chunk_size=${pb_chunk_size:-3500}

# pb_experimental_file_push:
#   Purpose  : Attempt real file uploads via /v2/upload-request and then "file" pushes.
#   Type     : boolean-like (true/false)
#   Default  : false (because pure-bash JSON parsing is brittle without jq)
#   Behavior : When true, the script will try to upload and push log files. On failure, it falls
#              back to including the local path in the summary note (your original behavior).
pb_experimental_file_push=${pb_experimental_file_push:-false}

# max_file_size:
#   Purpose  : Size threshold (MB) for log compression; if a log exceeds this, gzip and attach path.
#   Type     : integer (MB)
#   Default  : 8
#   Example  : 16
max_file_size=${max_file_size:-8}

# enable_btrfs_balance:
#   Purpose  : Enable btrfs balance step (duseage/musage capped at 50%).
#   Type     : boolean-like (true/false)
#   Default  : false (balance can be disruptive—enable only when needed)
enable_btrfs_balance=${enable_btrfs_balance:-false}

# enable_btrfs_defrag:
#   Purpose  : Enable btrfs filesystem defragmentation (recursive).
#   Type     : boolean-like (true/false)
#   Default  : false (defrag can be heavy—enable only when needed)
enable_btrfs_defrag=${enable_btrfs_defrag:-false}

# parallel_smart:
#   Purpose  : Concurrency cap for SMART checks to avoid I/O storms.
#   Type     : integer (>=1)
#   Default  : 2
#   Example  : 4 on fast/idle systems; keep low for busy/IO-bound hosts.
parallel_smart=${parallel_smart:-2}

# set_debug:
#   Purpose  : Turn on bash tracing (set -x) for troubleshooting.
#   Type     : string ("enabled" or "disabled")
#   Default  : disabled
#   Behavior : When "enabled", the script echoes commands as they run.
set_debug=${set_debug:-disabled}

if [[ -f "$CONFIG" ]]; then
  . "$CONFIG"
fi

[[ "$set_debug" == "enabled" ]] && set -x

if [[ "$(id -u)" -ne 0 ]]; then exec sudo /bin/bash "$0"; fi

LOCK_FD=9
LOCK_FILE=/var/lock/unattended_update.lock
exec {LOCK_FD}> "$LOCK_FILE"
flock -n "$LOCK_FD" || { echo "Another instance is running. Exiting."; exit 0; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || echo "Missing '$1'"; }
missing=()
for c in curl lsblk awk sed grep paste stat gzip findmnt; do [[ -n "$(need_cmd "$c")" ]] && missing+=("$c"); done
[[ ${#missing[@]} -gt 0 ]] && echo "Missing dependencies: ${missing[*]}" >&2

has_nvme=false; command -v nvme >/dev/null 2>&1 && has_nvme=true
has_smartctl=false; command -v smartctl >/dev/null 2>&1 && has_smartctl=true
has_btrfs=false; command -v btrfs >/dev/null 2>&1 && has_btrfs=true
has_timeout=false; command -v timeout >/dev/null 2>&1 && has_timeout=true

declare -A summary
declare -a summary_keys
add_summary() {
  local title=$1 body=$2
  summary["$title"]=$(printf "%s\n" "$body")
  summary_keys+=("$title")
}

run_and_capture() {
  local title=$1 cmd=$2 mp=${3:-n/a} t=${4:-0}
  local output exit_status=0

  if $has_timeout && (( t > 0 )); then
    output=$(bash -lc "set -o pipefail; timeout ${t}s $cmd" 2>&1) || exit_status=$?
  else
    output=$(bash -lc "set -o pipefail; $cmd" 2>&1) || exit_status=$?
  fi

  if (( exit_status != 0 )); then
    add_summary "$title" "$title failed on $mp (exit $exit_status)"
  else
    add_summary "$title" "$title completed on $mp"
  fi

  if [[ -n "$output" ]]; then
    local trimmed
    trimmed=$(printf "%s\n" "$output" | sed -e 's/\x0//g' | head -c 20000)
    add_summary "$title Output ($mp)" "$trimmed"
  fi
}

send_file_path() {
  local file_path=$1
  local title="Log file from HDD scans on $HOSTNAME"
  local max_bytes=$(( max_file_size * 1024 * 1024 ))
  local size; size=$(stat -c %s "$file_path" 2>/dev/null || echo 0)

  if (( size <= max_bytes )); then
    add_summary "$title" "$file_path"
  else
    add_summary "File Compression" "File $(basename "$file_path") > ${max_file_size}MB. Compressing…"
    gzip -c "$file_path" > "${file_path}.gz" || true
    local gzsize; gzsize=$(stat -c %s "${file_path}.gz" 2>/dev/null || echo 0)
    if (( gzsize <= max_bytes )); then
      add_summary "$title" "${file_path}.gz"
    else
      add_summary "File Compression" "Still > ${max_file_size}MB; will not attach."
    fi
  fi
}

check_smart() {
  local disk=$1
  local base; base=$(basename "$disk")
  local log_file="/var/log/smartctl_report_${base}.log"

  if [[ $disk == /dev/nvme* ]]; then
    if $has_nvme && nvme id-ctrl "$disk" &>/dev/null; then
      nvme smart-log "$disk" > "$log_file" 2>&1 || true
      send_file_path "$log_file"
      add_summary "NVMe SMART" "Collected SMART for $disk"
    else
      add_summary "NVMe SMART" "nvme-cli missing or disk inaccessible: $disk"
    fi
  else
    if $has_smartctl; then
      if smartctl -i "$disk" | grep -q -E "SMART support is: Available|SMART/Health Information"; then
        if ! smartctl -i "$disk" | grep -q "SMART support is: Enabled"; then
          smartctl -s on -o on -S on "$disk" || true
        fi
        smartctl -a "$disk" > "$log_file" 2>&1 || true
        send_file_path "$log_file"
        add_summary "SATA/SAS SMART" "Collected SMART for $disk"
      else
        add_summary "SATA/SAS SMART" "SMART not available on $disk"
      fi
    else
      add_summary "SATA/SAS SMART" "smartctl not found; skipping $disk"
    fi
  fi
}

mapfile -t FS_LINES < <(lsblk -pnro FSTYPE,MOUNTPOINT | awk 'NF==2 && $2!=""')
for line in "${FS_LINES[@]}"; do
  fstype=${line%% *}
  mountpoint=${line#* }

  case "$fstype" in
    btrfs)
      if $has_btrfs; then
        run_and_capture "Btrfs Scrub" "btrfs scrub start -Bd \"$mountpoint\"" "$mountpoint" 7200
        [[ "$enable_btrfs_balance" == "true" ]] && \
          run_and_capture "Btrfs Balance" "btrfs balance start -dusage=50 -musage=50 \"$mountpoint\"" "$mountpoint" 7200
        [[ "$enable_btrfs_defrag" == "true" ]] && \
          run_and_capture "Btrfs Defrag" "btrfs filesystem defragment -r \"$mountpoint\"" "$mountpoint" 7200
      else
        add_summary "Btrfs" "btrfs tools missing; skipping $mountpoint"
      fi
      ;;
    ext4)
      dev=$(findmnt -nro SOURCE --target "$mountpoint" || true)
      [[ -n "$dev" ]] && run_and_capture "Ext4 FSCK (dry-run)" "fsck -N \"$dev\"" "$mountpoint" 120
      ;;
    xfs)
      add_summary "XFS Check" "xfs_repair requires offline; skipping $mountpoint"
      ;;
    *)
      add_summary "FS Skipped" "Skipping $fstype on $mountpoint"
      ;;
  esac
done

mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
if (( ${#DISKS[@]} > 0 )); then
  add_summary "SMART" "Checking ${#DISKS[@]} disk(s) with parallelism=$parallel_smart"
  active=0
  for d in "${DISKS[@]}"; do
    check_smart "$d" &
    (( active++ ))
    if (( active >= parallel_smart )); then
      wait -n || true
      (( active-- ))
    fi
  done
  wait || true
else
  add_summary "SMART" "No disks found."
fi

pb_api="https://api.pushbullet.com"
pb_hdr_auth=( -H "Authorization: Bearer ${pushbullet_token}" )
pb_hdr_json=( -H "Content-Type: application/json" )

json_escape() {
  sed ':a;N;$!ba;s/\n/\\n/g;s/\\/\\\\/g;s/"/\\"/g'
}

pb_target_fields() {
  local t=""
  [[ -n "$pb_target_device_iden" ]] && t+="\"device_iden\":\"$pb_target_device_iden\","
  [[ -n "$pb_target_email" ]] && t+="\"email\":\"$pb_target_email\","
  [[ -n "$pb_channel_tag" ]] && t+="\"channel_tag\":\"$pb_channel_tag\","
  printf "%s" "$t"
}

pb_send_json() {
  curl -sS -D - -o /dev/null "${pb_hdr_auth[@]}" "${pb_hdr_json[@]}" \
    -X POST "$pb_api/v2/pushes" --data-binary "$1"
}

pb_note() {
  local title=$1 body=$2 extra target
  target=$(pb_target_fields)
  extra="{${target}\"type\":\"note\",\"title\":\"$(printf "%s" "$title" | json_escape)\",\"body\":\"$(printf "%s" "$body" | json_escape)\"}"
  pb_send_json "$extra"
}

pb_link() {
  local title=$1 body=$2 url=$3 target
  target=$(pb_target_fields)
  local payload="{${target}\"type\":\"link\",\"title\":\"$(printf "%s" "$title" | json_escape)\",\"body\":\"$(printf "%s" "$body" | json_escape)\",\"url\":\"$(printf "%s" "$url" | json_escape)\"}"
  pb_send_json "$payload"
}

pb_file_experimental() {
  local path=$1 fname mime; fname=$(basename "$path")
  mime=${2:-application/octet-stream}
  local req="{\"file_name\":\"$(printf "%s" "$fname" | json_escape)\",\"file_type\":\"$mime\"}"

  local resp; resp=$(curl -sS "${pb_hdr_auth[@]}" "${pb_hdr_json[@]}" -X POST "$pb_api/v2/upload-request" --data-binary "$req")
  local upload_url file_url
  upload_url=$(printf '%s' "$resp" | sed -n 's/.*"upload_url":"\([^"]*\)".*/\1/p')
  file_url=$(printf '%s' "$resp" | sed -n 's/.*"file_url":"\([^"]*\)".*/\1/p')

  if [[ -z "$upload_url" || -z "$file_url" ]]; then
    add_summary "Pushbullet file" "Failed to parse upload-request; sending path in note instead."
    return 1
  fi

  local up
  up=$(curl -sS -f -X POST "$upload_url" -F "file=@${path}" 2>&1) || {
    add_summary "Pushbullet file" "Upload failed; sending path in note instead."
    return 1
  }

  local target; target=$(pb_target_fields)
  local payload="{${target}\"type\":\"file\",\"file_name\":\"$(printf "%s" "$fname" | json_escape)\",\"file_type\":\"$mime\",\"file_url\":\"$(printf "%s" "$file_url" | json_escape)\",\"body\":\"Uploaded log from $HOSTNAME\"}"
  pb_send_json "$payload" >/dev/null
  add_summary "Pushbullet file" "Sent $fname as file push (experimental)."
}

build_summary() {
  local msg="Summary of operations on $HOSTNAME\n\n"
  for key in "${summary_keys[@]}"; do
    msg+=$(printf "%s:\n%s\n\n" "$key" "${summary[$key]}")
  done
  printf "%s" "$msg"
}

send_summary_pushes() {
  local summary_message; summary_message=$(build_summary)

  if [[ -z "$pushbullet_token" ]]; then
    printf "%s\n" "$summary_message"
    return
  fi

  local total=${#summary_message} idx=0 part=1
  while (( idx < total )); do
    local chunk=${summary_message:idx:pb_chunk_size}
    local title="Summary ($part) - $HOSTNAME"
    local headers; headers=$(pb_note "$title" "$chunk")
    idx=$(( idx + pb_chunk_size ))
    (( part++ ))
    if (( idx >= total )); then
      local limit rem reset
      limit=$(printf '%s' "$headers" | sed -n 's/^X-Ratelimit-Limit: *\([0-9]*\).*/\1/p' | tail -n1)
      rem=$(printf '%s' "$headers" | sed -n 's/^X-Ratelimit-Remaining: *\([0-9]*\).*/\1/p' | tail -n1)
      reset=$(printf '%s' "$headers" | sed -n 's/^X-Ratelimit-Reset: *\([0-9]*\).*/\1/p' | tail -n1)
      [[ -n "$limit" && -n "$rem" ]] && add_summary "Pushbullet rate-limit" "Remaining: ${rem}/${limit} (reset epoch: ${reset:-unknown})"
    fi
  done

  if [[ "$pb_send_link" == "true" && -n "$pb_link_url" ]]; then
    pb_link "Runbook/Reference - $HOSTNAME" "See link for details" "$pb_link_url" >/dev/null
  fi
}


# Optionally send files via PB (experimental)
send_collected_logs_as_files() {
  [[ "$pb_experimental_file_push" == "true" ]] || return 0
  for key in "${summary_keys[@]}"; do
    if [[ "$key" == "Log file from HDD scans on $HOSTNAME" ]]; then
      local path=${summary[$key]}
      [[ -f "$path" ]] && pb_file_experimental "$path" "text/plain" || true
    fi
  done
}

send_collected_logs_as_files
send_summary_pushes

exit
