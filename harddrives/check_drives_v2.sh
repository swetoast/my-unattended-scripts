#!/usr/bin/env bash
# Revision 15
# Configuration
CONFIG=/opt/etc/unattended_update.conf

# Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then exec sudo /bin/bash "$0"; fi

# Check if configuration file exists
if [ ! -f "$CONFIG" ]; then
    echo "No configuration file present at $CONFIG"
    exit 0
fi

# Source the configuration file
. "$CONFIG"

# Function to toggle debug setting
[ "$set_debug" = "enabled" ] && set -x || set +x

# Function to send a message
send_message() {
    local event=$1
    local body=$2
    local title="$HOSTNAME - $event"
    curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$body"
}

# Function to send a file
send_file() {
    local file_path=$1
    local file_name=$(basename "$file_path")
    local title="Here is a log file from HDD Scans on $HOSTNAME"

    # Check if the file size is less than the max size
    if [ $(stat -c%s "$file_path") -le $MAX_SIZE ]; then
        curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -X POST -F type=file -F file_name="$file_name" -F file=@$file_path -F title="$title"
    else
        send_message "File Compression" "File $file_name is larger than 25MB. Attempting to compress..."

        # Compress the file
        gzip -c "$file_path" > "$file_path.gz"

        # Check if the compressed file size is less than the max size
        if [ $(stat -c%s "$file_path.gz") -le $MAX_SIZE ]; then
            curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -X POST -F type=file -F file_name="$file_name.gz" -F file=@$file_path.gz -F title="$title"
        else
            # Send a Pushbullet message indicating that the file is too large
            send_message "File Compression" "Compressed file $file_name.gz is still larger than 25MB and will not be sent."
        fi
    fi
}

# Function to perform badblocks check
function badblocks_check {
    send_message "Badblocks Check" "Performing badblocks check on $1..."
    sudo badblocks -v $1
}

# Function to perform SMART test
function smart_test {
    send_message "SMART Test" "Performing SMART test on $1..."
    if [[ $1 == /dev/nvme* ]]; then
        sudo nvme smart-log $1
    else
        sudo smartctl -t long $1
    fi
}

# Function to check partition errors on SD cards
function fsck_check {
    send_message "Partition Error Check" "Checking partition errors on $1..."
    sudo fsck -n $1
}

# Function to clean system logs
clean_system_logs() {
    send_message "System Log Cleanup" "Cleaning system logs..."
    journalctl --rotate --vacuum-size=1M
}

# Function to trim ext4 filesystems and scrub btrfs filesystems
function check_filesystem {
    send_message "Filesystem Check" "Trimming ext4 filesystems and starting btrfs scrub..."
    df -T | awk '/btrfs/ {system("btrfs scrub start "$7)}'
    df -T | awk '/ext4/ {system("fstrim -Av")}'
}

# Function to perform checks on disks
function perform_checks {
    local disk_type=$1
    local disk_path=$2
    local check_function=$3

    for disk in $disk_path; do
        $check_function $disk
    done
}

# Function to perform btrfs balance
function btrfs_balance {
    send_message "Btrfs Balance" "Performing btrfs balance on $1..."
    sudo btrfs balance start -dusage=50 $1
}

# Function to perform ext4 filesystem check
function ext4_fsck {
    send_message "Ext4 Filesystem Check" "Performing ext4 filesystem check on $1..."
    sudo e2fsck -f $1
}

# Function to perform xfs filesystem check
function xfs_check {
    send_message "XFS Check" "Performing XFS check on $1..."
    sudo xfs_check $1
}

# Send start message
send_message "HDD Scan Start" "Started a HDD scan on $HOSTNAME on the $(date)"

# Perform checks
perform_checks "regular hard drives" "/dev/sd?" "badblocks_check"
perform_checks "regular hard drives" "/dev/sd?" "smart_test"
perform_checks "NVMe disks" "/dev/nvme[0-9]n[0-9]" "smart_test"
perform_checks "SD cards" "/dev/mmcblk[0-9]p[0-9]" "fsck_check"

# Check filesystem state of ext4 and btrfs filesystems and schedule fsck if not clean
df -T | awk '/ext4|btrfs/ {system(\"./check_filesystem_state \"$7)}'

# Perform btrfs balance on btrfs filesystems
df -T | awk '/btrfs/ {system(\"./btrfs_balance \"$7)}'

# Perform ext4 filesystem check on ext4 filesystems
df -T | awk '/ext4/ {system(\"./ext4_fsck \"$7)}'

# Perform xfs filesystem check on xfs filesystems
df -T | awk '/xfs/ {system(\"./xfs_check \"$7)}'

# Find log files larger than 1k and send them
find "$LOGS" -maxdepth 1 -type f -size +1k -exec send_file {} \\;

# Clean system logs
clean_system_logs
