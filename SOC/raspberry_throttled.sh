#!/bin/bash

config=/opt/etc/unattended_update.conf

if [ "$(id -u)" != "0" ]; then exec /usr/bin/sudo /bin/sh "$0"; fi

if [ -f $config ]
  then echo "Configuration file found at $config"
       echo "Updating Repository lists."
  else echo "No configuration file present at $config"
       exit 0
fi

throttled=$(vcgencmd get_throttled | cut -d "=" -f 2)
get_throttled=$(vcgencmd get_throttled | cut -d "=" -f 2 | cut -d "x" -f 2)

pushbullet_message () {
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="Throttling Detected on $(cat /etc/hostname)" -d body="Throttling Detected on $(cat /etc/hostname) Status code: $throttled"
}

if [ "$get_throttled" -ne 0 ]; then pushbullet_message; fi
