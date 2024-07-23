#!/usr/bin/env bash
# Revision 15
# Configuration

CONFIG=/opt/etc/unattended_update.conf

if [ "$(id -u)" != "0" ]; then exec sudo /bin/bash "$0"; fi

if [ ! -f "$CONFIG" ]; then
    echo "No configuration file present at $CONFIG"
    exit 0
fi

. "$CONFIG"

[ "$set_debug" = "enabled" ] && set -x || set +x

send_message() {
    local event=$1
    local body=$2
    local title="$HOSTNAME - $event"
    curl -u "$pushbullet_token": [1](https://api.pushbullet.com/v2/pushes) -d type=note -d title="$title" -d body="$body"
}

send_file() {
    local file_path=$1
    local file_name
    file_name=$(basename "$file_path")
    local title="Here is a log file from HDD Scans on $HOSTNAME"

    # Convert MAX_SIZE from MB to bytes
    local max_size_bytes=$((max_file_size * 1024 * 1024))

    if [ $(stat -c%s "$file_path") -le "$max_size_bytes" ]; then
        curl -u "$pushbullet_token": [1](https://api.pushbullet.com/v2/pushes) -X POST -F type=file -F file_name="$file_name" -F file=@"$file_path" -F title="$title"
    else
        send_message "File Compression" "File $file_name is larger than $max_file_size MB. Attempting to compress..."
        gzip -c "$file_path" > "$file_path.gz"
        if [ $(stat -c%s "$file_path.gz") -le "$max_size_bytes" ]; then
            curl -u "$pushbullet_token": [1](https://api.pushbullet.com/v2/pushes) -X POST -F type=file -F file_name="$file_name.gz" -F file=@"$file_path".gz -F title="$title"
        else
            send_message "File Compression" "Compressed file $file_name.gz is still larger than $max_file_size MB and will not be sent."
        fi
    fi
}

badblocks_check() {
    local disk=$1
    local badblocks_file="/var/log/badblocks-$disk.log"
    send_message "Badblocks Check" "Performing badblocks check on $disk..."
    badblocks -v -s -o "$badblocks_file" "$disk"
    if [ -s "$badblocks_file" ]; then
        send_message "Badblocks Check" "Badblocks found on $disk. Sending log file..."
        send_file "$badblocks_file"
    else
        send_message "Badblocks Check" "No badblocks found on $disk."
    fi
}

smart_test() {
    local disk=$1
    local smart_log_file="/var/log/smart-$disk.log"
    send_message "SMART Test" "Performing SMART test on $disk..."
    if [[ $disk == /dev/nvme* ]]; then
        nvme smart-log "$disk" > "$smart_log_file"
    else
        # Run the SMART test in the background
        smartctl -t long "$disk" > "$smart_log_file" &
        # Get the PID of the SMART test
        local smart_pid=$!
        # Wait for the SMART test to complete
        wait $smart_pid
    fi
    if [ -s "$smart_log_file" ]; then
        send_message "SMART Test" "SMART test completed on $disk. Sending log file..."
        send_file "$smart_log_file"
    else
        send_message "SMART Test" "No SMART data found on $disk."
    fi
}

fsck_check() {
    local fs_type=$1
    local disk=$2
    local fsck_log_file="/var/log/fsck-$disk.log"
    # Define the filesystem types you want to allow for fsck_check
    allowed_fs_types=("ext4" "xfs" "btrfs" "vfat" "zfs")
    if [[ " ${allowed_fs_types[*]} " =~ ${fs_type} ]]; then
        send_message "Partition Error Check" "Checking partition errors on $disk of type $fs_type..."
        case $fs_type in
            ext4)
                ext4_fsck "$disk" > "$fsck_log_file"
                ;;
            xfs)
                xfs_check "$disk" > "$fsck_log_file"
                ;;
            btrfs)
                check_btrfs "$disk" > "$fsck_log_file"
                ;;
            vfat)
                dosfsck -a "$disk" > "$fsck_log_file"
                ;;
            zfs)
                zfs_check "$disk" > "$fsck_log_file"
                ;;
            *)
                echo "Unsupported filesystem type: $fs_type"
                ;;
        esac
        if [ -s "$fsck_log_file" ]; then
            send_message "Partition Error Check" "Filesystem check completed on $disk. Sending log file..."
            send_file "$fsck_log_file"
        else
            send_message "Partition Error Check" "No filesystem errors found on $disk."
        fi
    else
        echo "Skipping fsck_check on disk $disk with unsupported filesystem type: $fs_type"
    fi
}

fs_maintenance() {
    local fs_type=$1
    local disk=$2
    # Define the filesystem types you want to allow for fs_maintenance
    allowed_fs_types=("ext4" "btrfs" "zfs")
    if [[ " ${allowed_fs_types[*]} " =~ ${fs_type} ]]; then
        send_message "Filesystem Maintenance" "Performing maintenance on $disk of type $fs_type..."
        case $fs_type in
            ext4)
                trim_ext4 "$disk"
                ;;
            btrfs)
                btrfs_maintance "$disk"
                ;;
            *)
                echo "Unsupported filesystem type for maintenance: $fs_type"
                ;;
        esac
    else
        echo "Skipping fs_maintenance on disk $disk with unsupported filesystem type: $fs_type"
    fi
}

clean_system_logs() {
    send_message "System Log Cleanup" "Cleaning system logs..."
    journalctl --rotate --vacuum-size=1M
}

check_btrfs() {
    send_message "Btrfs Check" "Starting btrfs scrub..."
    btrfs scrub start "$1"
}

btrfs_maintance() {
    send_message "Btrfs Balance" "Performing btrfs balance..."
    btrfs balance start -dusage=50 "$1"
}

trim_ext4() {
    send_message "Ext4 Trim" "Trimming ext4 filesystems..."
    fstrim -Av "$1"
}

ext4_fsck() {
    send_message "Ext4 Filesystem Check" "Performing ext4 filesystem check..."
    e2fsck -f "$1"
}

xfs_check() {
    send_message "XFS Check" "Performing XFS check..."
    xfs_repair "$1"
}

fat32_maintenance() {
    send_message "FAT32 Maintenance" "Performing FAT32 maintenance on $disk..."
    dosfsck -a "$1"
}

zfs_check() {

    local pool_name
    pool_name=$(zpool list -H -o name)
    if [ -z "$pool_name" ]; then
        echo "No ZFS pools found."
        return 1
    fi
    for pool_name in $pool_name; do
        send_message "ZFS Check" "Starting ZFS scrub on $pool_name..."
        zpool scrub "$pool_name"
    done
}

main() {
    for disk in /dev/sd? /dev/nvme[0-9]n[0-9] /dev/mmcblk[0-9]p[0-9]; do

        badblocks_check "$disk"
        smart_test "$disk"
 
        fs_type=$(blkid -o value -s TYPE "$disk")

        fsck_check "$fs_type" "$disk"
        fs_maintenance "$fs_type" "$disk"
    done
    clean_system_logs
}

main
