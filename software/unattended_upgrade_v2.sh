#!/bin/bash

# Define a list of package managers and their corresponding commands
declare -A pkg_managers=( ["apt"]="apt" ["yum"]="yum" ["dnf"]="dnf" ["zypper"]="zypper" ["pacman"]="pacman" ["snap"]="snap" ["flatpak"]="flatpak" )

# Load configuration
config="/opt/etc/unattended_update.conf"
if [ ! -f "$config" ]; then
  event="Error"
  pushbullet_message "$event" "No configuration file present at $config"
  exit 0
fi
source "$config"

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then exec sudo "$0"; fi

# Enable or disable debug mode
[ "${set_debug:-disabled}" = "enabled" ] && set -x || set +x

# Check online status
check_online() {
  local wait_seconds=0
  while ! ping -q -c 1 google.com >/dev/null 2>&1; do
    sleep 1
    ((wait_seconds++))
    [ $wait_seconds -gt 300 ] && echo "Not Online" && exit 1
  done
}

# Check disk space
check_disk_space() {
  local available
  available=$(df / --output=avail -BG | tail -1 | tr -dc '0-9')
  local event="Check Disk Space"
  if [ "$available" -lt "${disk_space_threshold:-0}" ]; then
    pushbullet_message "$event" "Only $available GB available, which is less than the threshold of ${disk_space_threshold:-0} GB."
    exit 1
  fi
}

# Function to handle package updates
update_packages() {
  local pkg_manager="$1"

  if command -v "$pkg_manager" >/dev/null 2>&1; then
    case $pkg_manager in
      apt) apt update ;;
      yum) yum check-update ;;
      dnf) dnf check-update ;;
      zypper) zypper refresh ;;
      pacman) pacman -Sy ;;
    esac
  fi
}

# Function to list packages and install updates
# Function to list packages and install updates
list_packages() {
  local pkg_manager="$1"
  local count
  local event="List Packages"
  local packagetype
  local message=""

  if command -v "$pkg_manager" >/dev/null 2>&1; then
    case $pkg_manager in
      apt) packagetype="deb"
           packagelist=$(apt list --upgradable | cut -d' ' -f1-2)
           pkglist=$(apt-get -su --assume-yes dist-upgrade)
           pending=$(echo "$pkglist" | grep -oE "[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove and [0-9]+ not upgraded\.")
           upgraded=$(echo "$pending" | grep -oE "[0-9]+ upgraded" | cut -d' ' -f1)
           installed=$(echo "$pending" | grep -oE "[0-9]+ newly installed" | cut -d' ' -f1)
           removed=$(echo "$pending" | grep -oE "[0-9]+ to remove" | cut -d' ' -f1)
           count=$(( $upgraded + $installed + $removed ))
           if [ "$count" -gt 0 ]; then
             message+="\nThere are $count $packagetype packages to be installed: $packagelist"
           fi ;;
      yum|dnf) packagetype="rpm"
                packagelist=$(yum check-update)
                count=$(echo "$packagelist" | wc -l)
                if [ "$count" -gt 0 ]; then
                  message+="\nThere are $count $packagetype packages to be installed: $packagelist"
                fi ;;
      zypper) packagetype="rpm"
               packagelist=$(zypper list-updates)
               count=$(echo "$packagelist" | wc -l)
               if [ "$count" -gt 0 ]; then
                 message+="\nThere are $count $packagetype packages to be installed: $packagelist"
               fi ;;
      pacman) packagetype="pkg.tar.xz"
              packagelist=$(pacman -Qu)
              pending=$(echo "$(pacman -Qu | wc -l) updates available")
              count=$(pacman -Qu | wc -l)
              if [ "$count" -gt 0 ]; then
                message+="\nThere are $count $packagetype packages to be installed: $packagelist"
              fi ;;
      snap) packagetype="snap"
            packagelist=$(snap refresh --list)
            pending=$(echo "$(snap refresh --list) updates available")
            count=$(snap refresh --list | wc -l)
            if [ "$count" -gt 0 ]; then
              message+="\nThere are $count $packagetype packages to be installed: $packagelist"
            fi ;;
      flatpak) packagetype="flatpak"
                packagelist=$(flatpak remote-ls --updates)
                count=$(echo "$packagelist" | wc -l)
                if [ "$count" -gt 0 ]; then
                  message+="\nThere are $count $packagetype packages to be installed: $packagelist"
                fi ;;
    esac
  fi

  # Send the message if it's not empty
  if [ -n "$message" ]; then
    pushbullet_message "$event" "$message"
  fi
}

# Function to install packages
install_packages() {
  local pkg_manager="$1"

  if command -v "$pkg_manager" >/dev/null 2>&1; then
    case $pkg_manager in
      apt) apt dist-upgrade -qq -y --assume-yes ;;
      yum|dnf) $pkg_manager upgrade -y ;;
      zypper) zypper up -y ;;
      pacman) pacman -Suuyy --noconfirm --needed --overwrite="*" ;;
      snap) snap refresh ;;
      flatpak) flatpak update -y ;;
    esac
  fi
}

# Function to handle package cleanups
cleanup_packages() {
  local pkg_manager="$1"

  if command -v "$pkg_manager" >/dev/null 2>&1; then
    case $pkg_manager in
      apt) apt autoremove -qq -y
           apt autoclean -qq -y
           apt -qq -y purge "$(dpkg -l | grep "^rc" | awk '{print $2}')" ;;
      yum|dnf) $pkg_manager autoremove -y
                $pkg_manager clean all ;;
      zypper) zypper clean --all ;;
      pacman) if command -v paccache >/dev/null 2>&1; then paccache -ruk0 ; fi
              pacman -Sc --noconfirm --needed
              pacman -Scc --noconfirm --needed ;;
        snap) LANG=en_US.UTF-8 snap list --all | awk '/disabled/{print $1, $3}' |
              while read -r snapname revision; do
                snap remove "$snapname" --revision="$revision"
              done ;;
    esac
  fi
}

# Function to check if a reboot is required
check_reboot_required() {
  local pkg_manager="$1"
  local event="Reboot required"
  local reboot_required=false

  if command -v "$pkg_manager" >/dev/null 2>&1; then
    case $pkg_manager in
      apt) [ -f /var/run/reboot-required ] && reboot_required=true ;;
      yum|dnf) [ -n "$(needs-restarting -r)" ] && reboot_required=true ;;
      pacman) 
        local kernel_pkg
        if uname -r | grep -q 'lts'; then kernel_pkg='linux-lts'
        elif uname -r | grep -q 'zen'; then kernel_pkg='linux-zen'
        elif uname -r | grep -q 'hardened'; then kernel_pkg='linux-hardened'
        elif uname -r | grep -q 'rpi'; then kernel_pkg='linux-rpi'
        else kernel_pkg='linux'; fi
        [[ $(pacman -Q $kernel_pkg | cut -d " " -f 2) > $(uname -r) ]] && reboot_required=true ;;
    esac
  fi
  [ "$reboot_required" = true ] && pushbullet_message "$event" "A reboot is required after an update."
}

# Send a message via Pushbullet
pushbullet_message() {
  local event="$1"
  local message="$2"
  local title="$HOSTNAME - $event"
  curl -u "${pushbullet_token:-}": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$message"
}

# Main script
check_online
check_disk_space
for pkg_manager in "${!pkg_managers[@]}"; do
  update_packages "$pkg_manager" "${pkg_managers[$pkg_manager]}"
  list_packages "$pkg_manager" 
  cleanup_packages "$pkg_manager"
  check_reboot_required "$pkg_manager"
done
