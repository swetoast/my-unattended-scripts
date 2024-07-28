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

# Function to perform scrub operation
scrub_btrfs() {
    local mountpoint=$1
    send_message "Scrub Operation" "Starting scrub operation on $mountpoint"
    btrfs scrub start -Bd $mountpoint &
    local pid=$!
    while ps -p $pid > /dev/null; do sleep 1; done
    if [ $? -ne 0 ]; then
        send_message "Scrub Operation" "Scrub operation failed on $mountpoint"
    else
        send_message "Scrub Operation" "Scrub operation completed on $mountpoint"
    fi
}

# Function to perform balance operation
balance_btrfs() {
    local mountpoint=$1
    send_message "Balance Operation" "Starting balance operation on $mountpoint"
    btrfs balance start -dusage=50 -musage=50 $mountpoint &
    local pid=$!
    while ps -p $pid > /dev/null; do sleep 1; done
    if [ $? -ne 0 ]; then
        send_message "Balance Operation" "Balance operation failed on $mountpoint"
    else
        send_message "Balance Operation" "Balance operation completed on $mountpoint"
    fi
}

# Function to perform defragmentation operation
defrag_btrfs() {
    local mountpoint=$1
    send_message "Defragmentation Operation" "Starting defragmentation operation on $mountpoint"
    btrfs filesystem defragment $mountpoint &
    local pid=$!
    while ps -p $pid > /dev/null; do sleep 1; done
    if [ $? -ne 0 ]; then
        send_message "Defragmentation Operation" "Defragmentation operation failed on $mountpoint"
    else
        send_message "Defragmentation Operation" "Defragmentation operation completed on $mountpoint"
    fi
}

# Function to perform file system check operation for ext4
check_ext4() {
    local mountpoint=$1
    send_message "File System Check" "Starting file system check operation on $mountpoint"
    fsck -N $mountpoint &
    local pid=$!
    while ps -p $pid > /dev/null; do sleep 1; done
    if [ $? -ne 0 ]; then
        send_message "File System Check" "File system check operation failed on $mountpoint"
    else
        send_message "File System Check" "File system check operation completed on $mountpoint"
    fi
}

# Function to check and enable S.M.A.R.T and generate reports
check_smart() {
    local disk=$1
    local log_file="/var/log/smartctl_report_$(basename "$disk").log"
    if [[ $disk == /dev/nvme* ]]; then
        if nvme smart-log "$disk" &> /dev/null; then
            nvme smart-log "$disk" > "$log_file"
            send_file "$log_file"
        else
            send_message "SMART Check" "SMART support is not available on $disk"
        fi
    else
        if smartctl -i "$disk" | grep -q -E "SMART support is: Available|SMART/Health Information"; then
            if ! smartctl -i "$disk" | grep -q "SMART support is: Enabled"; then
                smartctl --smart=on --offlineauto=on --saveauto=on "$disk"
            fi
            smartctl -a "$disk" > "$log_file"
            send_file "$log_file"
        else
            send_message "SMART Check" "SMART support is not available on $disk"
        fi
    fi
}

# Get a list of all partitions and their filesystems for the current device type
partitions=$(lsblk -f | grep -E 'nvme|sd|mmcblk' | grep -oE '(ext4|btrfs|xfs|vfat|/.*)' | paste -d' ' - -)

# Convert the string of partitions into an array
IFS=$'\n' read -rd '' -a partition_array <<<"$partitions"

# Loop through each partition
for partition_info in "${partition_array[@]}"
do
    # Get the file system type and mount point
    fstype=$(echo $partition_info | awk '{print $1}')
    mountpoint=$(echo $partition_info | awk '{print $2}')

    send_message "Filesystem Found" "Found $fstype filesystem at mount point: $mountpoint"

    # Check the file system type and perform the appropriate operations
    case $fstype in
        btrfs)
            scrub_btrfs $mountpoint
            balance_btrfs $mountpoint
            defrag_btrfs $mountpoint
            ;;
        ext4)
            check_ext4 $mountpoint
            ;;
        *)
            send_message "No Operation" "No maintenance operations defined for $fstype file systems."
            ;;
    esac
done

# Check and enable S.M.A.R.T for all disks
disks=$(lsblk -dn -o NAME | grep -E '^(sd[a-z]|nvme[0-9]n[0-9])$')
for disk in $disks; do
    check_smart "/dev/$disk"
done
