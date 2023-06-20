#!/bin/sh
# Rev 4

config=/opt/etc/unattended_update.conf

if [ "$(id -u)" != "0" ]; then exec /usr/bin/sudo /bin/sh "$0"; fi

if [ -f $config ]
  then echo "Configuration file found at $config"
       echo "Updating Repository lists."
  else echo "No configuration file present at $config"
       exit 0
fi

. $config

setting_debug_enabled () { set -x; }
setting_debug_disable () { set +x; }

if [ $set_debug = "enabled" ]; then setting_debug_enabled; fi

check_online () {
while ! ping -q -c 1 google.com >/dev/null 2>&1; do
  sleep 1
  WaitSeconds=$((WaitSeconds+1))
  [ $WaitSeconds -gt 300 ] && echo "Not Online"; exit 1
done
}

pushbullet_message () {
  message="$count pending $type packages will be updated here is the package list $packagelist"
  title="The following device will be updated: $(cat /etc/hostname)"
  curl -u $pushbullet_token: https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$message"
}

pushbullet_reboot_arch_message () {
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="Rebooting $(cat /etc/hostname)" -d body="Rebooting $(cat /etc/hostname) after a kernel update to version: $(pacman -Q linux | grep -oE "[0-9].+")"
}

pushbullet_reboot_deb_message () {
curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="Rebooting $(cat /etc/hostname)" -d body="Rebooting $(cat /etc/hostname) after a kernel update to new version"
}

check_packages () {
if [ "$count" -eq "0" ]
  then echo "No available updates on the following device: $(echo $HOSTNAME)"
  else echo "$count available updates on the following device: $(echo $HOSTNAME)\nHere is the package list\n $packagelist"
    if [ $(which kodi-send | wc -l) -eq 1 ]; then kodi-send --action="Notification($count available updates, Here is the packagelist: $packagelist,$timer)"; fi
    if [ $use_pushbullet = "enabled" ]; then pushbullet_message; fi
fi }

apt_list_packages () {
  type=debian
  packagelist=$(apt list --upgradable | cut -d' ' -f1-2)
  pkglist=$(apt-get -su --assume-yes dist-upgrade)
  pending=$(echo "$pkglist" | grep -oE "[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove and [0-9]+ not upgraded\.")
  upgraded=$(echo "$pending" | grep -oE "[0-9]+ upgraded" | cut -d' ' -f1)
  installed=$(echo "$pending" | grep -oE "[0-9]+ newly installed" | cut -d' ' -f1)
  removed=$(echo "$pending" | grep -oE "[0-9]+ to remove" | cut -d' ' -f1)
  count=$(( $upgraded + $installed + $removed ))
}

snap_list_packages () {
  type=snap
  packagelist=$(snap refresh --list)
  pending=$(echo "$(snap refresh --list) updates available")
  count=$(snap refresh --list | wc -l)
}

pacman_list_packages () {
  type=arch
  packagelist=$(pacman -Qu)
  pending=$(echo "$(pacman -Qu | wc -l) updates available")
  count=$(pacman -Qu | wc -l)
}

npm_list_packages () {
  type=nodejs
  packagelist=$(npm outdated)
  pending=$(echo "$(npm outdated | wc -l) updates available")
  count=$(npm outdated | wc -l)
}

opkg_list_packages () {
  type=opkg
  packagelist=$(opkg list-upgradable)
  pending=$(echo "$(opkg list-upgradable | wc -l) updates avalable")
  count=$(opkg list-upgradable | wc -l)
}

pip_list_packages () {
  type=python
  pending=$(echo "$(pip3 list -o | cut -f1 -d' ' | tr " " "\n" | awk '{if(NR>=3)print}' | cut -d' ' -f1 | wc -l) oudated python packages")
  packagelist=$(pip3 list -o | cut -f1 -d' ' | tr " " "\n" | awk '{if(NR>=3)print}' | cut -d' ' -f1)
  count=$(pip3 list -o | cut -f1 -d' ' | tr " " "\n" | awk '{if(NR>=3)print}' | cut -d' ' -f1 | wc -l)
}

pacman_upgrader () {
pacman -Sy
pacman_list_packages
check_packages
if [ "$count" -ge "1" ]; then
  pacman -Suuyy --noconfirm --needed --overwrite="*"
  if [ $(which paccache | wc -l) -eq 1 ]; then paccache -ruk0 ; fi
  pacman -Sc --noconfirm --needed
  pacman -Scc --noconfirm --needed
fi
}

apt_upgrader () {
  apt_list_packages
  check_packages
  if [ "$count" -ge "1" ]
    then apt-get dist-upgrade -qq -y --assume-yes
         apt-get autoremove -qq -y
         apt-get autoclean -qq -y
         apt-get -qq -y purge $(/usr/bin/dpkg -l | /bin/grep "^rc" | /usr/bin/awk '{print $2}')
  fi
  if [ $(cat /proc/version | grep -oE "osmc" | wc -l) -ge 1 ]; then kodi_upgrader; fi
}

ipkg_upgrader () {
  ipkg upgrade
}

kodi_upgrader () {
  if systemctl is-enabled mediacenter.service >/dev/null 2>&1 && ! systemctl is-active mediacenter.service >/dev/null 2>&1
           then systemctl restart mediacenter.service; fi
  sleep 60
  kodi-send \
      --action="Notification(No updates available, Checking for updates in Kodi Repository,$timer)" \
      --action="UpdateAddonRepos" \
      --action="UpdateLocalAddons"
}

nodejs_upgrader () {
  npm_list_packages
  check_packages
  if [ "$count" -ge "1" ]
    then npm update -g
  fi }

opkg_upgrader () {
  PATH=/opt/bin/go/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/builtin/sbin:/usr/builtin/bin:/usr/local/sbin:/usr/local/bin:/opt/sbin:/opt/bin
  opkg_list_packages
  check_packages
  if [ "$count" -ge "1" ]
    then opkg upgrade
  fi }

rust_upgrader () {
source /home/$USERNAME/.cargo/env
if [ $(su - $USERNAME -c "which rustup" | wc -l) -eq 1 ]; then su - $USERNAME -c "rustup update";fi
if [ $(su - $USERNAME -c "which cargo" | wc -l) -eq 1 ]; then su - $USERNAME -c "cargo install-update -a";fi
if [ $(su - $USERNAME -c "which cargo-cache" | wc -l) -eq 1 ]; then su - $USERNAME -c "cargo-cache -ae";fi
}

python_upgrader () {
  pip_list_packages
  check_packages
  if [ "$count" -ge "1" ]
    then pip3 list -o | cut -f1 -d' ' | tr " " "\n" | awk '{if(NR>=3)print}' | cut -d' ' -f1 | xargs -n1 pip3 install -U
  fi }

snap_upgrader () {
snap_list_packages
snap refresh
set -eu
LANG=en_US.UTF-8 snap list --all | awk '/disabled/{print $1, $3}' |
    while read snapname revision; do
        snap remove "$snapname" --revision="$revision"
    done
}

detect_updater () {
  if [ $(which ipkg | wc -l) -eq 1 ]; then ipkg update; ipkg_upgrader; fi
  if [ $(which opkg | wc -l) -eq 1 ]; then opkg update; opkg_upgrader; fi
  if [ $(which apt | wc -l) -eq 1 ]; then apt-get update; apt_upgrader; fi
  if [ $(which pacman | wc -l) -eq 1 ]; then pacman_upgrader; fi
  if [ $(which pip | wc -l) -eq 1 ]; then python_upgrader; fi
  if [ $(which npm | wc -l) -eq 1 ]; then nodejs_upgrader; fi
  if [ $(su - $USERNAME -c "which rustup" | wc -l) -eq 1 ]; then rust_upgrader; fi
}

reboot_check () {
if [ "$needs_reboot" = "enabled" ]; then
case $(hostnamectl | grep "Operating System" | cut -d ":" -f 2 | awk '{print $1 }') in
Raspbian) if [ -f /var/run/reboot-required ]
          then if [ $use_pushbullet = "enabled" ]; then pushbullet_reboot_deb_message; fi; sleep 5; reboot; fi ;;
  Debian) if [ -f /var/run/reboot-required ]
          then if [ $use_pushbullet = "enabled" ]; then pushbullet_reboot_deb_message; fi; sleep 5; reboot; fi ;;
  Ubuntu) if [ -f /var/run/reboot-required ]
          then if [ $use_pushbullet = "enabled" ]; then pushbullet_reboot_deb_message; fi; sleep 300; reboot; fi ;;
    Arch) rpicheck=$(cat /proc/device-tree/model | awk '{ print $1 }')
          if [ "$rpicheck" = "Raspberry" ]; 
          then active_kernel=$(uname -r | grep -oE "([0-9]+\.)+[0-9]+((-[0-9])+)?")
               current_kernel=$(pacman -Q linux-rpi | grep -oE "[0-9].+")
          else active_kernel=$(uname -r | grep -oE "([0-9]+\.)+[0-9]+((-[0-9])+)?")
               current_kernel=$(pacman -Q linux | grep -oE "[0-9].+")
          fi
          if ! [ "$active_kernel" = "$current_kernel" ]; then
          if [ $use_pushbullet = "enabled" ]; then pushbullet_reboot_arch_message; fi; sleep 5; reboot; fi ;;
esac
fi
}

check_online
detect_updater
reboot_check

if [ $set_debug = "enabled" ]; then setting_debug_disable; fi
