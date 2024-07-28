#!/bin/bash
# Revision 15

CONFIG=/opt/etc/unattended_update.conf

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
    curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$body"
}

send_file() {
    local file_path=$1
    local file_name
    file_name=$(basename "$file_path")
    local title="Here is a log file from HDD Scans on $HOSTNAME"
    local max_size_bytes=$((max_file_size * 1024 * 1024))

    if [ $(stat -c%s "$file_path") -le "$max_size_bytes" ]; then
        curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -X POST -F type=file -F file_name="$file_name" -F file=@"$file_path" -F title="$title"
    else
        send_message "File Compression" "File $file_name is larger than $max_file_size MB. Attempting to compress..."
        gzip -c "$file_path" > "$file_path.gz"
        if [ $(stat -c%s "$file_path.gz") -le "$max_size_bytes" ]; then
            curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -X POST -F type=file -F file_name="$file_name.gz" -F file=@"$file_path".gz -F title="$title"
        else
            send_message "File Compression" "Compressed file $file_name.gz is still larger than $max_file_size MB and will not be sent."
        fi
    fi
}

run_command() {
    local command=$1
    local mountpoint=$2
    local message=$3
    send_message "$message" "Starting $message on $mountpoint"
    eval "$command" &
    local pid=$!
    while ps -p $pid > /dev/null; do sleep 1; done
    if [ $? -ne 0 ]; then
        send_message "$message" "$message failed on $mountpoint"
    else
        send_message "$message" "$message completed on $mountpoint"
    fi
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
            run_command "btrfs scrub start -Bd $mountpoint" $mountpoint "Scrub Operation"
            run_command "btrfs balance start -dusage=50 -musage=50 $mountpoint" $mountpoint "Balance Operation"
            run_command "btrfs filesystem defragment $mountpoint" $mountpoint "Defragmentation Operation"
            ;;
        ext4)
            run_command "fsck -N $mountpoint" $mountpoint "File System Check"
            ;;
    esac
done

disks=$(lsblk -dn -o NAME | grep -E '^(sd[a-z]|nvme[0-9]n[0-9])$')
for disk in $disks; do
    check_smart "/dev/$disk"
done
