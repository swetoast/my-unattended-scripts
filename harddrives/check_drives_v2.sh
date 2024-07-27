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

badblocks_check() {
    local disk=$1
    local badblocks_file="/var/log/badblocks-$disk.log"
    send_message "Badblocks Check" "Performing badblocks check on $disk..."
    
    if [[ "$disk" == /dev/sd[a-z] ]]; then
        badblocks -v -s -o "$badblocks_file" "$disk" &
        local badblocks_pid=$!
        wait $badblocks_pid 
    fi   
    
    if [ -s "$badblocks_file" ]; then
        send_message "Badblocks Check" "Badblocks found on $disk. Sending log file..."
        send_file "$badblocks_file"
    else
        send_message "Badblocks Check" "No badblocks found on $disk."
    fi
}

smartctl_check() {
    local disk=$1
    local smart_log_file="/var/log/smart-$disk.log"
    
    local smart_status=$(smartctl -i "$disk" | grep "SMART support is: Enabled")
    if [ -z "$smart_status" ]; then
        smartctl --smart=on --offlineauto=on --saveauto=on "$disk"
    fi

    send_message "SMART Test" "Pulling SMART data from $disk..."
    
    if [[ "$disk" == /dev/nvme[0-9] ]]; then
        nvme smart-log "$disk" > "$smart_log_file"
    elif [[ "$disk" == /dev/sd[a-z] ]]; then
        smartctl -a "$disk" > "$smart_log_file" &
    fi
    
    if [ -s "$smart_log_file" ]; then
        send_message "SMART Test" "SMART data pulled from $disk. Sending log file..."
        send_file "$smart_log_file"
    else
        send_message "SMART Test" "No SMART data found on $disk."
    fi
}

fsck_check() {
    df -T | grep -E "ext4|xfs|btrfs|zfs" | awk '{print $2 " " $7}' | while read -r type mount_point; do
        send_message "Partition Error Check" "Checking partition errors on $mount_point of type $type..."
        case $type in
            ext4)
                ext4_check "$mount_point"
                ;;
            xfs)
                xfs_check "$mount_point"
                ;;
            btrfs)
                btrfs_check "$mount_point"
                ;;
            zfs)
                zfs_check "$mount_point"
                ;;
            *)
                echo "Unsupported filesystem type: $type"
                ;;
        esac
    done
}

fs_maintenance() {
    df -T | grep -E "ext4|btrfs" | awk '{print $2 " " $7}' | while read -r type mount_point; do
        send_message "Filesystem Maintenance" "Performing maintenance on $mount_point of type $type..."
        case $type in
            ext4)
                ext4_maintenance "$mount_point"
                ;;
            btrfs)
                btrfs_maintenance "$mount_point"
                ;;
            *)
                echo "Unsupported filesystem type for maintenance: $type"
                ;;
        esac
    done
}

btrfs_check() {
    send_message "Btrfs Check" "Starting btrfs scrub on $1..."
    btrfs scrub start -B "$1"
    while true; do
        status=$(btrfs scrub status "$1")
        if echo $status | grep -q "finished"; then
            send_message "Btrfs Check" "Scrub finished on $1."
            break
        else
            sleep 60
        fi
    done
}


ext4_check() {
    send_message "Ext4 Filesystem Check" "Performing ext4 filesystem check..."
    e2fsck -C 0 -f "$1"
}

xfs_check() {
    send_message "XFS Check" "Performing XFS check..."
    xfs_repair "$1"
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

        while true; do
            status=$(zpool status "$pool_name")
            if echo $status | grep -q "scan: scrub repaired"; then
                send_message "ZFS Check" "Scrub finished on $pool_name."
                break
            else
                sleep 60
            fi
        done
    done
}

btrfs_maintenance() {
    send_message "Btrfs Balance" "Performing btrfs balance..."
    btrfs balance start -dusage=50 "$1"

    # Wait for the balance to finish
    while true; do
        status=$(btrfs balance status "$1")
        if echo $status | grep -q "No balance"; then
            send_message "Btrfs Balance" "Balance finished on $1."
            break
        else
            sleep 60
        fi
    done
}

ext4_maintenance() {
    send_message "Ext4 Trim" "Trimming ext4 filesystems..."
    trim_output=$(fstrim -Av "$1")
    send_message "Ext4 Trim" "Trimming finished. Output: $trim_output"
}

clean_system_logs() {
    send_message "System Log Cleanup" "Cleaning system logs..."
    journalctl --rotate --vacuum-size=1M
}

# Main function
badblocks_check
smarttest_check
fsck_check
fs_maintenance
clean_system_logs
