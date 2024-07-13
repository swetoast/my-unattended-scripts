#!/usr/bin/env sh

# Define a list of package managers and their corresponding commands
declare -A pkg_managers=( ["apt"]="apt" ["yum"]="yum" ["dnf"]="dnf" ["zypper"]="zypper" ["pacman"]="pacman" ["snap"]="snap" ["flatpak"]="flatpak" )

# Load configuration
config="/opt/etc/unattended_update.conf"
if [ ! -f "$config" ]; then
  local event="Error"
  pushbullet_message "$event" "No configuration file present at $config"
  exit 0
fi
. "$config"

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then exec sudo "$0"; fi

# Enable or disable debug mode
[ "$set_debug" = "enabled" ] && set -x || set +x

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
  local available=$(df / | tail -1 | awk '{print $4}')
  available=${available%.*}
  local event="Check Disk Space"
  if [ "$available" -lt "$disk_space_threshold" ]; then
    pushbullet_message "$event" "Only $available KB available, which is less than the threshold of $disk_space_threshold KB."
    exit 1
  fi
}

# Function to handle package updates
update_packages() {
  local pkg_manager=$1
  local update_cmd=$2

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      snap) snap refresh ;;
      flatpak) flatpak update -y ;;
      apt) apt update ;;
      yum) yum check-update ;;
      dnf) dnf check-update ;;
      zypper) zypper refresh ;;
      pacman) pacman -Sy ;;
    esac
  fi
}

# Function to list packages and install updates
list_packages() {
  local pkg_manager=$1
  local count
  local event="List Packages"

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      apt) pkglist=$(apt-get -su --assume-yes dist-upgrade)
           pending=$(echo "$pkglist" | grep -oE "[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove and [0-9]+ not upgraded\.")
           read -r upgraded installed removed _ <<< $(echo "$pending" | grep -oE "[0-9]+" | tr '\n' ' ')
           count=$(( upgraded + installed + removed ))
           [ "$count" -gt 0 ] && install_packages $pkg_manager ;;
      yum|dnf) count=$(yum check-update | wc -l)
                [ "$count" -gt 0 ] && install_packages $pkg_manager ;;
      zypper) count=$(zypper list-updates | wc -l)
               [ "$count" -gt 0 ] && install_packages $pkg_manager ;;
      pacman) count=$(pacman -Qu | wc -l)
               [ "$count" -gt 0 ] && install_packages $pkg_manager ;;
      snap) count=$(snap changes | grep -c "Done.*Refresh snap")
             [ "$count" -gt 0 ] && install_packages $pkg_manager ;;
      flatpak) count=$(flatpak remote-ls --updates | wc -l)
                [ "$count" -gt 0 ] && install_packages $pkg_manager ;;
    esac
  fi
}

# Function to install packages
install_packages() {
  local pkg_manager=$1
  local pkg_list=$2

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      apt) apt dist-upgrade -qq -y --assume-yes ;;
      yum|dnf) $pkg_manager upgrade -y ;;
      zypper) zypper up -y ;;
      pacman) pacman -Suuyy --noconfirm --needed --overwrite="*" ;;
    esac
  fi
}

# Function to handle package cleanups
cleanup_packages() {
  local pkg_manager=$1

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      apt) apt autoremove -qq -y
           apt autoclean -qq -y
           apt -qq -y purge $(dpkg -l | grep "^rc" | awk '{print $2}') ;;
      yum|dnf) $pkg_manager autoremove -y
                $pkg_manager clean all ;;
      zypper) zypper clean --all ;;
      pacman) if command -v paccache >/dev/null 2>&1; then paccache -ruk0 ; fi
              pacman -Sc --noconfirm --needed
              pacman -Scc --noconfirm --needed ;;
    esac
  fi
}

# Send a message via Pushbullet
pushbullet_message() {
  local event=$1
  local message=$2
  local title="$HOSTNAME - $event"
  curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$message"
}

# Function to check if a reboot is required
check_reboot_required() {
  local pkg_manager=$1
  local event="Reboot required"
  local reboot_required=false

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      apt) [ -f /var/run/reboot-required ] && reboot_required=true ;;
      yum|dnf) [ -n "$(needs-restarting -r)" ] && reboot_required=true ;;
      pacman) checkupdates | grep -q "^linux " && reboot_required=true ;;
    esac
  fi

  if [ "$reboot_required" = true ]; then
    pushbullet_message "$event" "A reboot is required after an update."
  fi
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
