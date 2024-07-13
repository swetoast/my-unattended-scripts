#!/usr/bin/env sh

# Define a list of package managers and their corresponding commands
declare -A pkg_managers=( ["apt"]="apt-get" ["yum"]="yum" ["dnf"]="dnf" ["zypper"]="zypper" ["pacman"]="pacman" ["snap"]="snap" ["flatpak"]="flatpak" )

# Load configuration
config="/opt/etc/unattended_update.conf"
if [ ! -f "$config" ]; then
  echo "No configuration file present at $config"
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

# Function to handle package updates
update_packages() {
  local pkg_manager=$1
  local update_cmd=$2

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      snap) snap refresh ;;
      flatpak) flatpak update -y ;;
      *) $update_cmd update ;;
    esac
  fi
}

# Function to list packages available for updates
list_packages() {
  local pkg_manager=$1
  local count

  if command -v $pkg_manager >/dev/null 2>&1; then
    echo "Number of packages available for updates for $pkg_manager:"
    case $pkg_manager in
      apt) pkglist=$(apt-get -su --assume-yes dist-upgrade)
           pending=$(echo "$pkglist" | grep -oE "[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove and [0-9]+ not upgraded\.")
           read -r upgraded installed removed _ <<< $(echo "$pending" | grep -oE "[0-9]+" | tr '\n' ' ')
           count=$(( upgraded + installed + removed ))
           echo "$count updates available"
           [ "$count" -gt 0 ] && pushbullet_message "$count" "apt" "$pkglist" ;;
      yum|dnf) count=$(yum check-update | wc -l)
                echo "$count updates available"
                [ "$count" -gt 0 ] && pushbullet_message "$count" "$pkg_manager" "$(yum check-update)" ;;
      zypper) count=$(zypper list-updates | wc -l)
               echo "$count updates available"
               [ "$count" -gt 0 ] && pushbullet_message "$count" "zypper" "$(zypper list-updates)" ;;
      pacman) count=$(pacman -Qu | wc -l)
               echo "$count updates available"
               [ "$count" -gt 0 ] && pushbullet_message "$count" "pacman" "$(pacman -Qu)" ;;
      snap) count=$(snap changes | grep -c "Done.*Refresh snap")
             echo "$count updates available"
             [ "$count" -gt 0 ] && pushbullet_message "$count" "snap" "$(snap changes)" ;;
      flatpak) count=$(flatpak remote-ls --updates | wc -l)
                echo "$count updates available"
                [ "$count" -gt 0 ] && pushbullet_message "$count" "flatpak" "$(flatpak remote-ls --updates)" ;;
    esac
    echo
  fi
}

# Function to handle package cleanups
cleanup_packages() {
  local pkg_manager=$1

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      apt) apt-get autoremove -qq -y
           apt-get autoclean -qq -y
           apt-get -qq -y purge $(dpkg -l | grep "^rc" | awk '{print $2}') ;;
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
  local count=$1 type=$2 packagelist=$3
  local message="$count pending $type packages will be updated. Here is the package list: $packagelist"
  local title="The following device will be updated: $HOSTNAME"
  curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$message"
}

# Send a reboot message via Pushbullet
pushbullet_reboot_message() {
  local kernel_version=$1
  local title="Rebooting $HOSTNAME"
  local body="Rebooting $HOSTNAME after a kernel update to version: $kernel_version"
  curl -u "$pushbullet_token": https://api.pushbullet.com/v2/pushes -d type=note -d title="$title" -d body="$body"
}

# Function to check if a reboot is required
check_reboot_required() {
  local pkg_manager=$1

  if command -v $pkg_manager >/dev/null 2>&1; then
    case $pkg_manager in
      apt) if [ -f /var/run/reboot-required ]; then
             echo "Reboot required!"
             pushbullet_reboot_message "$(uname -r)"
           fi ;;
      yum|dnf) if [ -n "$(needs-restarting -r)" ]; then
                  echo "Reboot required!"
                  pushbullet_reboot_message "$(uname -r)"
                fi ;;
      pacman) if checkupdates | grep -q "^linux "; then
                 echo "Reboot required!"
                 pushbullet_reboot_message "$(uname -r)"
               fi ;;
    esac
  fi
}

# Main script
check_online
for pkg_manager in "${!pkg_managers[@]}"; do
  update_packages "$pkg_manager" "${pkg_managers[$pkg_manager]}"
  list_packages "$pkg_manager"
  cleanup_packages "$pkg_manager"
  check_reboot_required "$pkg_manager"
done
