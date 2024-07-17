#!/usr/bin/env bash
# Rev 10

CONFIG=/opt/etc/unattended_update.conf
LOGS="$CONFIG/logs"  # Assuming logs directory is inside the CONFIG directory

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
toggle_debug() {
    [ "$set_debug" = "enabled" ] && set -x || set +x
}

# Function to send a startup message
startup_message() {
    curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="HDD Scan" -d body="Started a HDD scan on $HOSTNAME on the $(date)"
}

# Function to send a notification message
notification_message() {
    find "$LOGS" -maxdepth 1 -type f -size +1k -exec cat {} \; | while read -r SUMMARY; do
        message="$SUMMARY"
        title="Here is a summary for HDD Scans from $HOSTNAME"
        curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$message"
    done
}

# Function to check filesystem
check_filesystem() {
    df -T | awk '/btrfs/ {system("btrfs scrub start "$7)}'
    df -T | awk '/ext4/ {system("fstrim -Av")}'
}

# Function to check logs
check_logs() {
    find "$LOGS" -maxdepth 1 -type f -size +1k -exec notification_message {} \;
}

# Function to clean system logs
clean_system_logs() {
    journalctl --rotate --vacuum-size=1M
}

# Function to check drives
check_drives() {
    mkdir -p "$LOGS"/blocks
    mkdir -p "$LOGS"/smart
    run_"$PREFAPP"
    run_smartctl
}

# Function to run disk check tools
run_disk_check_tool() {
    local tool=$PREFAPP
    local log_dir=$2
    if command -v "$tool" &> /dev/null; then
        for DEVICE in /dev/sd* /dev/nvme* /dev/mmcblk*; do
            "$tool" scan "$DEVICE" -o "$LOGS/$log_dir/$(basename "$DEVICE").log"
            chown "$USERNAME":users "$LOGS/$log_dir/$(basename "$DEVICE").log"
        done
    fi
}

# Function to run smartctl
run_smartctl() {
    if command -v smartctl &> /dev/null; then
        for DEVICE in /dev/sd*; do
            smartctl -H "$DEVICE" | grep -E "PASSED|FAILED" > "$LOGS/smart/$(basename "$DEVICE").log"
            chown "$USERNAME":users "$LOGS/smart/$(basename "$DEVICE").log"
            smartctl -t long "$DEVICE"
        done
    fi
}

# Main script execution
toggle_debug
startup_message
clean_system_logs
check_drives
run_disk_check_tool bbf blocks
run_disk_check_tool badblocks blocks
check_filesystem
check_logs
toggle_debug
