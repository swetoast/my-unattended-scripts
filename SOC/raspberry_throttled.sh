#!/bin/bash                                                                                                                                         #!/bin/bash
# Rev 1
if [ "$(id -u)" != "0" ]; then exec sudo /bin/bash "$0"; fi
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

throttled=$(vcgencmd get_throttled | cut -d "=" -f 2)
get_throttled=$(vcgencmd get_throttled | cut -d "=" -f 2 | cut -d "x" -f 2)

pushbullet_message () {
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="Throttling Detected on $(cat /etc/hostname)" -d body="Throttling Detected on $(cat /etc/hostname) Status code: $throttled"
}

check_throttled () {
if [ "$get_throttled" -ne 0 ]; then pushbullet_message; fi
}

if [ "$set_debug" = "enabled" ]; then setting_debug_disable; fi

check_throttled
