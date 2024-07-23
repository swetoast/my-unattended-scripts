#!/bin/bash
# Configuration
set -x
CONFIG=/opt/etc/unattended_update.conf

if [ "$(id -u)" != "0" ]; then exec sudo /bin/bash "$0"; fi

if [ ! -f "$CONFIG" ]; then
    echo "No configuration file present at $CONFIG"
    exit 0
fi

. "$CONFIG"

# Function to send messages
send_message() {
    local event=$1
    local body=$2
    local title="$HOSTNAME - $event"
    curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$body"
}

# Function to send files
send_file() {
    local file_path=$1
    local file_name
    file_name=$(basename "$file_path")
    local title="Here is a log file from HDD Scans on $HOSTNAME"

    # Convert MAX_SIZE from MB to bytes
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

# Function to perform badblocks check
badblocks_check() {
    local disk=$1
    local badblocks_file="/var/log/badblocks-$disk.log"
    send_message "Badblocks Check" "Performing badblocks check on $disk..."
    
    # Run badblocks in the background
    badblocks -v -s -o "$badblocks_file" "$disk" &
    
    # Get the PID of the badblocks command
    local badblocks_pid=$!
    
    # Wait for the badblocks command to complete
    wait $badblocks_pid
    
    if [ -s "$badblocks_file" ]; then
        send_message "Badblocks Check" "Badblocks found on $disk. Sending log file..."
        send_file "$badblocks_file"
    else
        send_message "Badblocks Check" "No badblocks found on $disk."
    fi
}

# Function to perform SMART test
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

# Function to perform filesystem check
fsck_check() {
    # Use df -T to get the filesystem type and mount point for all mounted filesystems
    df -T | grep -E "ext4|xfs|btrfs|vfat|zfs" | awk '{print $2 " " $7}' | while read -r type mount_point; do
        send_message "Partition Error Check" "Checking partition errors on $mount_point of type $type..."
        case $type in
            ext4)
                ext4_fsck "$mount_point"
                ;;
            xfs)
                xfs_check "$mount_point"
                ;;
            btrfs)
                check_btrfs "$mount_point"
                ;;
            vfat)
                dosfsck -a "$mount_point"
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

# Function to perform filesystem maintenance
fs_maintenance() {
    # Use df -T to get the filesystem type and mount point for all mounted filesystems
    df -T | grep -E "ext4|btrfs|zfs" | awk '{print $2 " " $7}' | while read -r type mount_point; do
        send_message "Filesystem Maintenance" "Performing maintenance on $mount_point of type $type..."
        case $type in
            ext4)
                trim_ext4 "$mount_point"
                ;;
            btrfs)
                btrfs_maintance "$mount_point"
                ;;
            *)
                echo "Unsupported filesystem type for maintenance: $type"
                ;;
        esac
    done
}

# Function to clean system logs
clean_system_logs() {
    send_message "System Log Cleanup" "Cleaning system logs..."
    journalctl --rotate --vacuum-size=1M
}

# Main function
main() {
    # Get the device associated with the mount point
    for device in $(ls /dev/sd[a-z] /dev/mmcblk[0-9]p[0-9] /dev/nvme[0-9]n[0-9]); do
        # Only run badblocks on HDDs (sd[a-z])
        if [[ "$device" == /dev/sd[a-z] ]]; then
            badblocks_check "$device"
        fi

        # Skip SMART test on SD cards
        if [[ "$device" != /dev/mmcblk[0-9]* ]]; then
            smart_test "$device"
        fi
    done

    # Perform filesystem check and maintenance
    fsck_check
    fs_maintenance

    clean_system_logs
}

main
