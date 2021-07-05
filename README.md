# My unattended scripts
Like the repo name says, here is some stuff that im tweaking on while having nothing better todo.

Here is an example config for the scripts above

```config
#Enable or disable features here
use_pushbullet="disable"                                # enabled / disabled (default: disabled)
use_pushover="disabled"                                 # enabled / disabled (default: disabled)

#Pushbullet/Pushover settings
pushbullet_token=""                                     # Your access token here (https://docs.pushbullet.com/)
pushover_token=""                                       # Your access token here (https://pushover.net/api)
pushover_username=""                                    # Pushover User ID (the user/group key (not e-mail address often referred to as USER_KEY)

#General settings
set_debug="disabled"                                    # Set debug option to show exit codes if enabled. Values: enabled/disabled (Default Value: disabled)

#Settings for script such as where to store logs and usernames.
HOSTNAME="My Machine"
USERNAME="pi"
LOGS=/home/pi/logs/
```
