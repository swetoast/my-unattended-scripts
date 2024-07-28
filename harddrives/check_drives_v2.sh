#!/bin/bash
# Revision 15

CONFIG=/opt/etc/unattended_update.conf

# Add a summary array to store the results
declare -A summary

if [ "$(id -u)" != "0" ]; then exec sudo /bin/bash "$0"; fi

if [ ! -f "$CONFIG" ]; then
    echo "No configuration file present at $CONFIG"
    exit 0
fi

. "$CONFIG"

[ "${set_debug:-disabled}" = "enabled" ] && set -x || set +x

send_message() {
    local event=$1
    local body=$2
    local title="$HOSTNAME - $event"
    # Accumulate messages instead of sending them immediately
    # Use printf to interpret the newline character
    summary["$title"]=$(printf "%s\n" "$body")
}

send_file() {
    local file_path=$1
    local file_name
    file_name=$(basename "$file_path")
    local title="Here is a log file from HDD Scans on $HOSTNAME"
    local max_size_bytes=$((max_file_size * 1024 * 1024))

    if [ $(stat -c%s "$file_path") -le "$max_size_bytes" ]; then
        # Accumulate file path instead of file content
        send_message "$title" "$file_path"
    else 
        send_message "File Compression" "File $file_name is larger than $max_file_size MB. Attempting to compress..."
        gzip -c "$file_path" > "$file_path.gz"
        if [ $(stat -c%s "$file_path.gz") -le "$max_size_bytes" ]; then
            # Accumulate file path instead of file content
            send_message "$title" "$file_path.gz"
        else 
            send_message "File Compression" "Compressed file $file_name.gz is still larger than $max_file_size MB and will not be sent."
        fi
    fi
}

run_command() {
    local command=$1
    local mountpoint=$2
    local message=$3
    # Capture the output of the command
    local output
    output=$(eval "$command")
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        send_message "$message" "$message failed on $mountpoint"
    else 
        send_message "$message" "$message completed on $mountpoint"
    fi
    # Return the output of the command
    echo "$output"
}

check_smart() {
    local disk=$1
    local log_file="/var/log/smartctl_report_$(basename "$disk").log"
    if [[ $disk == /dev/nvme* ]]; then
        if nvme smart-log "$disk" &> /dev/null; then
            nvme smart-log "$disk" > "$log_file"
            send_file "$log_file"
        fi
    else 
        if smartctl -i "$disk" | grep -q -E "SMART support is: Available|SMART/Health Information"; then
            if ! smartctl -i "$disk" | grep -q "SMART support is: Enabled"; then
                smartctl --smart=on --offlineauto=on --saveauto=on "$disk"
            fi
            smartctl -a "$disk" > "$log_file"
            send_file "$log_file"
        fi
    fi
}

partitions=$(lsblk -f | grep -E 'nvme|sd|mmcblk' | grep -oE '(ext4|btrfs|xfs|vfat|/.*)' | paste -d' ' - -)
IFS=$'\n' read -rd '' -a partition_array <<<"$partitions"

for partition_info in "${partition_array[@]}"; do
    fstype=$(echo $partition_info | awk '{print $1}')
    mountpoint=$(echo $partition_info | awk '{print $2}')

    case $fstype in
        btrfs)
            scrub_output=$(run_command "btrfs scrub start -Bd $mountpoint" $mountpoint "Scrub Operation")
            send_message "Scrub Output on $mountpoint" "$scrub_output"
            balance_output=$(run_command "btrfs balance start -dusage=50 -musage=50 $mountpoint" $mountpoint "Balance Operation")
            send_message "Balance Output on $mountpoint" "$balance_output"
            defrag_output=$(run_command "btrfs filesystem defragment $mountpoint" $mountpoint "Defragmentation Operation")
            send_message "Defrag Output on $mountpoint" "$defrag_output"
            ;;
        ext4)
            fsck_output=$(run_command "fsck -N $mountpoint" $mountpoint "File System Check")
            send_message "FSCK Output on $mountpoint" "$fsck_output"
            ;;
    esac
done

disks=$(lsblk -dn -o NAME | grep -E '^(sd[a-z]|nvme[0-9]n[0-9])$')
for disk in $disks; do
    check_smart "/dev/$disk"
done

# At the end of the script, send a summary message
summary_message="Summary of operations:\n"
for key in "${!summary[@]}"; do
    # Use printf to preserve the newlines in each message
    summary_message+=$(printf "%s:\n%s\n\n" "$key" "${summary[$key]}")
done
# Send the accumulated summary message
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note --data-urlencode title="Summary" --data-urlencode body="$summary_message"
