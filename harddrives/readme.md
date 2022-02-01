# Check Disk

Set this to a cronjob, it will scan regular harddrives, m2 and sd cards

Configuration Values | description
:--- | :---
PREFAPP | bbf / badblocks 
USERNAME | username for the system
LOGS | desired path to logs
use_pushbullet | enabled / disabled
pushbullet_token | your tolken for pushbullet
set_debug | enabled / disabled

## Example Config

Here is an example config for the scripts above, store at `/opt/etc/unattended_update.conf`

```
#Enable or disable features here
use_pushbullet="disabled"                                # enabled / disabled (default: disabled)

#Pushbullet/Pushover settings
pushbullet_token=""                                     # Your access token here (https://docs.pushbullet.com/)

#General settings
set_debug="disabled"                                    # Set debug option to show exit codes if enabled. Values: enabled/disabled (Default Value: disabled)

#Settings for script such as where to store logs and usernames.
HOSTNAME="My Machine"
USERNAME="pi"
LOGS=/home/pi/logs
```
