#!/usr/bin/env bash
# Rev 13

CONFIG=/opt/etc/unattended_update.conf
MAX_SIZE=26214400  # 25MB in bytes

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

# Function to send a message
send_message() {
    local body=$1
    local title="HDD Scan on $HOSTNAME"
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
        send_message "File $file_name is larger than 25MB. Attempting to compress..."

        # Compress the file
        gzip -c "$file_path" > "$file_path.gz"

        # Check if the compressed file size is less than the max size
        if [ $(stat -c%s "$file_path.gz") -le $MAX_SIZE ]; then
            curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -X POST -F type=file -F file_name="$file_name.gz" -F file=@$file_path.gz -F title="$title"
        else
            # Send a Pushbullet message indicating that the file is too large
            send_message "Compressed file $file_name.gz is still larger than 25MB and will not be sent."
        fi
    fi
}

# Function to check filesystem
check_filesystem() {
    df -T | awk '/btrfs/ {system("btrfs scrub start "$7)}'
    df -T | awk '/ext4/ {system("fstrim -Av")}'
}

# Function to clean system logs
clean_system_logs() {
    journalctl --rotate --vacuum-size=1M
}

# Function to check drives
check_drives() {
    mkdir -p "$LOGS"/blocks
    mkdir -p "$LOGS"/smart
    run_disk_check_tool "$PREFAPP" blocks
    run_smartctl
}

# Function to run disk check tools
run_disk_check_tool() {
    local tool=$1
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
            if grep -q "PASSED" "$LOGS/smart/$(basename "$DEVICE").log"; then
                send_file "$LOGS/smart/$(basename "$DEVICE").log"
            fi
            smartctl -t long "$DEVICE"
        done
    fi
}

# Main script execution
toggle_debug
send_message "Started a HDD scan on $HOSTNAME on the $(date)"
clean_system_logs
check_drives
check_filesystem
find "$LOGS" -maxdepth 1 -type f -size +1k -exec send_file {} \;
toggle_debug
