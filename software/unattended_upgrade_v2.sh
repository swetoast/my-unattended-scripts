#!/bin/bash
# Revision 11
# Define a list of package managers and their corresponding commands
declare -A pkg_managers=( ["apt"]="apt" ["yum"]="yum" ["dnf"]="dnf" ["zypper"]="zypper" ["pacman"]="pacman" ["snap"]="snap" ["flatpak"]="flatpak" )

# Load configuration
config="/opt/etc/unattended_update.conf"
if [ ! -f "$config" ]; then
  echo "No configuration file present at $config"
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
      npm) npm outdated -g ;;
    esac
  fi
}

# Function to list package updates and start installation
list_packages() {
  local pkg_manager="$1"
  local count
  local event="List Packages"
  local message=""
  local packagelist=""
  
  if command -v "$pkg_manager" >/dev/null 2>&1; then
    case $pkg_manager in
          apt) packagelist=$(apt list --upgradable 2>/dev/null | awk -F'[: /]' 'NR>2 {print $1, $8, ">", $3}')
               packagetype=$(echo apt)
               count=$(echo -n "$packagelist" | grep -c .)
            ;;
      yum|dnf) packagelist=$(yum -q check-update | sed '/^$/d')
               packagetype=$(echo rpm)
               count=$(echo -n "$packagelist" | grep -c .)
             ;;
       zypper) packagelist=$(zypper list-updates | awk 'NR>3 {print $3}')
               packagetype=$(echo rpm)
               count=$(echo -n "$packagelist" | grep -c .)
             ;;
       pacman) packagelist=$(pacman -Qu)
               packagetype=$(echo pkg)
               count=$(echo -n "$packagelist" | grep -c .)
             ;;
         snap) packagelist=$(snap refresh --list 2>&1 | grep -vE "All snaps up to date.")
               packagetype=$(echo snap)
               count=$(echo -n "$packagelist" | grep -c .)
             ;;
      flatpak) packagelist=$(flatpak remote-ls --updates 2>&1 | grep -vE "Looking for updates\?|Nothing to do\." | awk 'NR>1 {print $2, $3}' | grep -v "is end-of-life")
               packagetype=$(echo flatpak)
               count=$(echo -n "$packagelist" | grep -c .)
             ;;
          npm)  
               packagelist=$(npm outdated -g --depth=0)
               packagetype=$(echo npm)
               count=$(echo -n "$packagelist" | grep -c .)
             ;;
    esac

    if [ "$count" -gt 0 ]; then
      message=$(printf "There are $count $packagetype packages to be installed: \n$packagelist")
      pushbullet_message "$event" "$message"
      install_packages "$pkg_manager"
    fi
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
      npm) npm update -g ;;
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
        snap) snap list --all | awk '/disabled/{print $1, $3}' |
              while read -r snapname revision; do
                snap remove "$snapname" --revision="$revision"
              done ;;
         npm) npm cache clean --force ;;
    esac
  fi
}

# Function to check if a reboot is required and reboot if necessary
check_reboot_required() {
  local event="Reboot required"
  local reboot_required=false

  for pkg_manager in "${!pkg_managers[@]}"; do
    reboot_required=false
    if command -v "$pkg_manager" >/dev/null 2>&1; then
      case $pkg_manager in
        apt) 
          [ -f /var/run/reboot-required ] && reboot_required=true 
          ;;
        yum|dnf) 
          [ -n "$(needs-restarting -r)" ] && reboot_required=true 
          ;;
        pacman) 
          kernel_pkg=$(pacman -Q | grep -E 'linux(-lts|-zen|-hardened|-rpi(-16k)?)? ' | cut -d " " -f 1)
          kernel_version=$(uname -r | sed -e 's/-lts//' -e 's/-zen//' -e 's/-hardened//' -e 's/-rpi//' -e 's/-rpi-16k//')
          if [[ $(echo -e "$(pacman -Q $kernel_pkg | cut -d " " -f 2)\n$kernel_version" | sort -Vr | head -n 1) != $kernel_version ]]; then
            reboot_required=true
          fi 
          ;;
      esac
    fi
    if [ "$reboot_required" = true ]; then break; fi
  done

  if [ "$reboot_required" = true ]; then
    if [ "${reboot_after_update:-false}" = true ]; then
      pushbullet_message "$event" "A reboot is required after an update. The system will reboot now."
      sync; sleep 60; reboot
    else
      pushbullet_message "$event" "A reboot is required after an update. The system needs to be rebooted."
    fi
  fi
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
done
check_reboot_required
