#!/bin/bash
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

function_startup_message () {
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="HDD Scan" -d body="Started a Antivirus scan on $HOSTNAME on the $(date)"
}

function_notification_message () {
message="$(for SUMMARY in $(find "$LOGS" -maxdepth 1 -type f -size +1k); do cat "$SUMMARY"; done)"
title="Here is a summary for HDD Scans from $HOSTNAME"
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$message"
}

function_check_logs () {
for SUMMARY in $(find "$LOGS" -maxdepth 1 -type f -size +1k); do function_notification_message; done
}

function_clean_logs () {
mkdir -p $LOGS/antivirus
rm $LOGS/antivirus/*
}

function_scan_system () {
/usr/bin/clamscan --recursive --allmatch --infected --move=/home/toast/.infected --log=/home/toast/logs/antivirus/avscan.log /  
}

option="${1}"
case ${option} in
   -pre) function_startup_message
         function_clean_logs ;;
      *) function_scan_system ;;
  -post) function_notification_message ;;
esac

if [ "$set_debug" = "enabled" ]; then setting_debug_disable; fi
