#!/usr/bin/env bash
# Revision 17

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONFIG=${CONFIG:-/opt/etc/unattended_update.conf}
LOCK_FILE=${LOCK_FILE:-/run/lock/disk_maintenance.lock}
LOG_DIR=${LOG_DIR:-/var/log/disk-maintenance}
PUSHBULLET_API='https://api.pushbullet.com/v2'

# Defaults. The configuration file may override these values.
pushbullet_token=''
pb_channel_tag=''
pb_target_device_iden=''
pb_target_email=''
pb_send_link=false
pb_link_url=''
pb_chunk_size=3500
pb_upload_logs=false
max_file_size=8
enable_btrfs_balance=false
enable_btrfs_defrag=false
parallel_smart=2
set_debug=disabled
btrfs_timeout=7200
smart_timeout=300

if (( EUID != 0 )); then
  exec sudo --preserve-env=CONFIG -- "$0" "$@"
fi

if [[ -f $CONFIG ]]; then
  config_owner=$(stat -c '%u' "$CONFIG")
  if [[ $config_owner != 0 ]] || [[ -n $(find "$CONFIG" -maxdepth 0 -perm /022 -print -quit) ]]; then
    printf 'Unsafe ownership or permissions on %s. Require root ownership and no group/other write access.\n' "$CONFIG" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$CONFIG"
fi

[[ $set_debug == enabled ]] && set -x

for command in awk cat curl date find findmnt flock gzip head hostname install lsblk mktemp sed sort stat timeout tr; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command" >&2
    exit 1
  }
done

[[ $pb_chunk_size =~ ^[0-9]+$ ]] && (( pb_chunk_size >= 500 )) || {
  printf 'pb_chunk_size must be an integer of at least 500.\n' >&2
  exit 1
}
[[ $max_file_size =~ ^[0-9]+$ ]] || {
  printf 'max_file_size must be a non-negative integer.\n' >&2
  exit 1
}
[[ $parallel_smart =~ ^[0-9]+$ ]] && (( parallel_smart >= 1 )) || {
  printf 'parallel_smart must be an integer of at least 1.\n' >&2
  exit 1
}
[[ $btrfs_timeout =~ ^[0-9]+$ ]] && [[ $smart_timeout =~ ^[0-9]+$ ]] || {
  printf 'Timeout values must be non-negative integers.\n' >&2
  exit 1
}

target_count=0
[[ -n $pb_channel_tag ]] && ((target_count += 1))
[[ -n $pb_target_device_iden ]] && ((target_count += 1))
[[ -n $pb_target_email ]] && ((target_count += 1))
(( target_count <= 1 )) || {
  printf 'Set at most one Pushbullet target.\n' >&2
  exit 1
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf 'Another disk-maintenance run is already active.\n'
  exit 0
fi

install -d -m 0750 "$LOG_DIR"
WORK_DIR=$(mktemp -d /tmp/disk-maintenance.XXXXXX)
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT HUP INT TERM

HOST_NAME=${HOSTNAME:-$(hostname)}
RUN_STAMP=$(date '+%Y%m%d-%H%M%S')
SUMMARY_FILE="$WORK_DIR/summary.txt"
: >"$SUMMARY_FILE"

add_summary() {
  local title=$1
  local body=$2
  printf '%s\n%s\n\n' "$title" "$body" >>"$SUMMARY_FILE"
}

run_capture() {
  local title=$1
  local mountpoint=$2
  local timeout_seconds=$3
  shift 3
  local output_file="$WORK_DIR/command-${RANDOM}-${RANDOM}.log"
  local rc=0

  if (( timeout_seconds > 0 )); then
    timeout --signal=TERM --kill-after=30s "${timeout_seconds}s" "$@" >"$output_file" 2>&1 || rc=$?
  else
    "$@" >"$output_file" 2>&1 || rc=$?
  fi

  if (( rc == 0 )); then
    add_summary "$title" "Completed on $mountpoint."
  elif (( rc == 124 || rc == 137 )); then
    add_summary "$title" "Timed out on $mountpoint after ${timeout_seconds} seconds."
  else
    add_summary "$title" "Failed on $mountpoint with exit status $rc."
  fi

  if [[ -s $output_file ]]; then
    add_summary "$title output ($mountpoint)" "$(head -c 20000 "$output_file" | tr -d '\000')"
  fi
  return "$rc"
}

prepare_log() {
  local source=$1
  local size max_bytes compressed
  max_bytes=$((max_file_size * 1024 * 1024))
  size=$(stat -c '%s' "$source" 2>/dev/null || printf '0')
  if (( max_bytes > 0 && size > max_bytes )); then
    compressed="${source}.gz"
    gzip -c -- "$source" >"$compressed"
    printf '%s\n' "$compressed"
  else
    printf '%s\n' "$source"
  fi
}

smart_worker() {
  local disk=$1
  local result=$2
  local base log rc=0 status report_path
  base=$(basename "$disk")
  log="$LOG_DIR/smart-${base}-${RUN_STAMP}.log"

  if ! command -v smartctl >/dev/null 2>&1; then
    printf 'SMART %s\nsmartctl is not installed; skipped %s.\n\n' "$disk" "$disk" >"$result"
    return 0
  fi

  timeout --signal=TERM --kill-after=15s "${smart_timeout}s" smartctl -x "$disk" >"$log" 2>&1 || rc=$?
  report_path=$(prepare_log "$log")

  if (( rc == 0 )); then
    status='Completed with no SMART warning bits set.'
  elif (( rc & 7 )); then
    status="Unable to complete the SMART query correctly (status $rc)."
  else
    status="SMART reported health or error-log warnings (status $rc)."
  fi

  printf 'SMART %s\n%s\nReport: %s\n\n' "$disk" "$status" "$report_path" >"$result"
}

if command -v btrfs >/dev/null 2>&1; then
  declare -A seen_btrfs=()
  while read -r source target; do
    [[ -n $target ]] || continue
    fsid=$(findmnt -nro UUID --target "$target" 2>/dev/null || true)
    key=${fsid:-$source}
    [[ -n ${seen_btrfs[$key]:-} ]] && continue
    seen_btrfs[$key]=1

    run_capture 'Btrfs scrub' "$target" "$btrfs_timeout" btrfs scrub start -Bd -- "$target" || true
    if [[ $enable_btrfs_balance == true ]]; then
      run_capture 'Btrfs balance' "$target" "$btrfs_timeout" btrfs balance start -dusage=50 -musage=50 -- "$target" || true
    fi
    if [[ $enable_btrfs_defrag == true ]]; then
      run_capture 'Btrfs defragmentation' "$target" "$btrfs_timeout" btrfs filesystem defragment -r -- "$target" || true
    fi
  done < <(findmnt -rn -t btrfs -o SOURCE,TARGET)
else
  add_summary 'Btrfs' 'btrfs tools are not installed; Btrfs maintenance was skipped.'
fi

while read -r source target; do
  [[ -n $target ]] || continue
  add_summary "Ext4 $target" "Mounted from $source. Online e2fsck was skipped; perform a real check while unmounted or during boot."
done < <(findmnt -rn -t ext4 -o SOURCE,TARGET)

while read -r source target; do
  [[ -n $target ]] || continue
  add_summary "XFS $target" "Mounted from $source. xfs_repair was skipped because repair requires the filesystem to be unmounted."
done < <(findmnt -rn -t xfs -o SOURCE,TARGET)

mapfile -t DISKS < <(lsblk -dpnro NAME,TYPE | awk '$2 == "disk" {print $1}' | sort -u)
if ((${#DISKS[@]} == 0)); then
  add_summary 'SMART' 'No physical disks were found.'
else
  add_summary 'SMART' "Checking ${#DISKS[@]} physical disk(s), with up to $parallel_smart concurrent checks."
  result_files=()
  active=0
  index=0
  for disk in "${DISKS[@]}"; do
    result="$WORK_DIR/smart-result-${index}.txt"
    result_files+=("$result")
    smart_worker "$disk" "$result" &
    ((active += 1))
    ((index += 1))
    if (( active >= parallel_smart )); then
      wait -n || true
      ((active -= 1))
    fi
  done
  wait || true
  for result in "${result_files[@]}"; do
    [[ -f $result ]] && cat "$result" >>"$SUMMARY_FILE"
  done
fi

pushbullet_args() {
  if [[ -n $pb_target_device_iden ]]; then
    printf '%s\n' 'device_iden' "$pb_target_device_iden"
  elif [[ -n $pb_target_email ]]; then
    printf '%s\n' 'email' "$pb_target_email"
  elif [[ -n $pb_channel_tag ]]; then
    printf '%s\n' 'channel_tag' "$pb_channel_tag"
  fi
}

pb_post() {
  local endpoint=$1
  shift
  curl --silent --show-error --fail-with-body --max-time 60 \
    --retry 2 --retry-delay 2 \
    --header "Access-Token: $pushbullet_token" \
    --request POST "$PUSHBULLET_API/$endpoint" "$@"
}

pb_note() {
  local title=$1 body=$2
  local args=(--data-urlencode 'type=note' --data-urlencode "title=$title" --data-urlencode "body=$body")
  local target=()
  mapfile -t target < <(pushbullet_args)
  if ((${#target[@]} == 2)); then
    args+=(--data-urlencode "${target[0]}=${target[1]}")
  fi
  pb_post pushes "${args[@]}" >/dev/null
}

pb_link() {
  local args=(--data-urlencode 'type=link' --data-urlencode "title=Runbook - $HOST_NAME" --data-urlencode 'body=Open the configured reference link.' --data-urlencode "url=$pb_link_url")
  local target=()
  mapfile -t target < <(pushbullet_args)
  if ((${#target[@]} == 2)); then
    args+=(--data-urlencode "${target[0]}=${target[1]}")
  fi
  pb_post pushes "${args[@]}" >/dev/null
}

pb_upload_file() {
  local path=$1 mime='text/plain' response upload_url file_url file_name
  command -v jq >/dev/null 2>&1 || return 1
  file_name=$(basename "$path")

  response=$(pb_post upload-request \
    --data-urlencode "file_name=$file_name" \
    --data-urlencode "file_type=$mime") || return 1
  upload_url=$(jq -r '.upload_url // empty' <<<"$response")
  file_url=$(jq -r '.file_url // empty' <<<"$response")
  [[ -n $upload_url && -n $file_url ]] || return 1

  local upload_args=()
  while IFS= read -r entry; do
    upload_args+=(--form-string "$entry")
  done < <(jq -r '.data // {} | to_entries[] | "\(.key)=\(.value)"' <<<"$response")
  upload_args+=(--form "file=@$path")

  curl --silent --show-error --fail --max-time 300 \
    --request POST "$upload_url" "${upload_args[@]}" >/dev/null || return 1

  local args=(--data-urlencode 'type=file' --data-urlencode "file_name=$file_name" --data-urlencode "file_type=$mime" --data-urlencode "file_url=$file_url" --data-urlencode "body=Disk report from $HOST_NAME")
  local target=()
  mapfile -t target < <(pushbullet_args)
  if ((${#target[@]} == 2)); then
    args+=(--data-urlencode "${target[0]}=${target[1]}")
  fi
  pb_post pushes "${args[@]}" >/dev/null
}

send_summary() {
  local message total offset part chunk
  message=$(printf 'Disk maintenance summary for %s\n\n' "$HOST_NAME"; cat "$SUMMARY_FILE")

  if [[ -z $pushbullet_token ]]; then
    printf '%s\n' "$message"
    return 0
  fi

  total=${#message}
  offset=0
  part=1
  while (( offset < total )); do
    chunk=${message:offset:pb_chunk_size}
    pb_note "Disk maintenance $HOST_NAME, part $part" "$chunk" || {
      printf 'Pushbullet summary delivery failed.\n' >&2
      return 1
    }
    ((offset += pb_chunk_size))
    ((part += 1))
  done

  if [[ $pb_upload_logs == true ]]; then
    while IFS= read -r path; do
      [[ -f $path ]] || continue
      pb_upload_file "$path" || printf 'Pushbullet file upload failed for %s.\n' "$path" >&2
    done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "smart-*-${RUN_STAMP}.log*" -print)
  fi

  if [[ $pb_send_link == true && -n $pb_link_url ]]; then
    pb_link || printf 'Pushbullet link delivery failed.\n' >&2
  fi
}

send_summary
