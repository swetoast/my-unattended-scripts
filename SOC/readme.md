A Simple script that can run on cronjob every x minutes to check if the charger is working as inteneded if not it notifies 

Here is an example config for the scripts above, store at `/opt/etc/unattended_update.conf`

```config
#Enable or disable features here
use_pushbullet="disabled"                                # enabled / disabled (default: disabled)

#Pushbullet
pushbullet_token=""                                     # Your access token here (https://docs.pushbullet.com/)

#General settings
set_debug="disabled"                                    # Set debug option to show exit codes if enabled. Values: enabled/disabled (Default Value: disabled)

#Settings for script such as where to store logs and usernames.
HOSTNAME="My Machine"
USERNAME="pi"
LOGS=/home/pi/logs
```
