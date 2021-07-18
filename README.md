# My unattended scripts
Like the repo name says, here is some stuff that im tweaking on while having nothing better todo, most of my script uses this config file below.

Here is an example config for the scripts above, store at `/opt/etc/unattended_update.conf`

```config
#Enable or disable features here
use_pushbullet="disable"                                # enabled / disabled (default: disabled)

#Pushbullet/Pushover settings
pushbullet_token=""                                     # Your access token here (https://docs.pushbullet.com/)

#General settings
set_debug="disabled"                                    # Set debug option to show exit codes if enabled. Values: enabled/disabled (Default Value: disabled)

#Settings for script such as where to store logs and usernames.
HOSTNAME="My Machine"
USERNAME="pi"
LOGS=/home/pi/logs
```
