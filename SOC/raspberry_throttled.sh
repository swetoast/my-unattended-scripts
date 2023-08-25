#!/bin/bash
# Rev 2

CONFIG=/opt/etc/unattended_update.conf

if [ ! -f "$CONFIG" ]
    then    echo "No configuration file present at $CONFIG"
            exit 0
fi

. "$CONFIG"

setting_debug_enabled () { set -x; }
setting_debug_disable () { set +x; }

if [ "$set_debug" = "enabled" ]; then setting_debug_enabled; fi

get_throttled=$(vcgencmd get_throttled | cut -d "=" -f 2)
get_temperature=$(vcgencmd measure_temp | cut -d "=" -f 2)
get_voltage=$(vcgencmd measure_volts | cut -d "=" -f 2)

pushbullet_message () {
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="Throttling Detected on $(cat /etc/hostname)" -d body="Current status is $current"
}

check_throttled () {
case $get_throttled in
0x10000) current=$(echo "Under-voltage has occurred, current voltage is $get_voltage") pushbullet_message ;;
0x20000) current=$(echo "Arm frequency capping has occurred") pushbullet_message ;;
0x40000) current=$(echo "Throttling has occurred") pushbullet_message ;;
0x80000) current=$(echo "Soft temperature limit has occurred, current tempature is $get_temperature") pushbullet_message ;;
esac
}

if [ "$set_debug" = "enabled" ]; then setting_debug_disable; fi

check_throttled
