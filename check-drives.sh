#!/usr/bin/env bash
# Rev 5
if [ "$(id -u)" != "0" ]; then exec sudo /bash "$0"; fi
CONFIG=/opt/etc/unattended_update.conf

if [ -f "$CONFIG" ]
    then    echo "Configuration file found at $CONFIG"
    else    echo "No configuration file present at $CONFIG"
            exit 0
fi

. "$CONFIG"

setting_debug_enabled () { set -x; }
setting_debug_disable () { set +x; }

if [ "$set_debug" = "enabled" ]; then setting_debug_enabled; fi

startup_message () {
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="HDD Scan" -d body="Started a HDD scan on $HOSTNAME on the $(date)"
}

notification_message () {
message="$(for SUMMARY in $(find $LOGS -maxdepth 1 -type f -size +1k); do cat $SUMMARY; done)"
title="$(cat /etc/hostname) reported bad sectors"
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$message"
}

check_drives () {

mkdir -p $LOGS/{blocks/smart}

for DEVICE in $( ls /dev/sd[a-z] | cut -d '/' -f3); do /usr/local/bin/bbf scan /dev/"$DEVICE" -o "$LOGS/$DEVICE_blocks.log";chown $myusername:users $LOGS/blocks/$DEVICE.log; done
for DEVICE in $( ls /dev/mmcblk0p[0-9] | cut -d '/' -f3); do /usr/local/bin/bbf scan /dev/"$DEVICE" -o "$LOGS/$DEVICE_blocks.log";chown $myusername:users $LOGS/blocks/$DEVICE.log; done
for DEVICE in $( ls /dev/sd[a-z] | cut -d '/' -f3); do smartctl -H /dev/$DEVICE >> $LOGS/$DEVICE_smart.log; smartctl --test=long /dev/$DEVICE;chown $myusername:users $LOGS/smart/$DEVICE.log; done

if [ $(df -T | grep btrfs | awk '{ print $7 }' | wc -l) -ge 1 ]; then
for BTRFS in $(df -T | grep btrfs | awk '{ print $7 }'); do btrfs scrub start $BTRFS; done;fi
}

check_logs () {
for SUMMARY in $(find $LOGS -maxdepth 1 -type f -size +1k); do notification_message; done
}

clean_system_logs () {
journalctl --rotate --vacuum-size=1M
}

startup_message
clean_system_logs
check_drives
check_logs

if [ "$set_debug" = "enabled" ]; then setting_debug_disable; fi
