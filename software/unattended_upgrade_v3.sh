#!/usr/bin/env bash
# Revision 12

set -uo pipefail
umask 077
export LC_ALL=C
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

readonly CONFIG='/opt/etc/unattended_update.conf'
readonly LOCK_FILE='/run/lock/unattended_update.lock'
readonly PUSHBULLET_URL='https://api.pushbullet.com/v2/pushes'

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

if [[ ! -f "$CONFIG" ]]; then
  printf 'No configuration file present at %s\n' "$CONFIG"
  exit 0
fi

config_owner=$(stat -c '%u' "$CONFIG")
if [[ $config_owner != 0 ]] || [[ -n $(find "$CONFIG" -maxdepth 0 -perm /022 -print -quit) ]]; then
  printf 'Unsafe ownership or permissions on %s; require root ownership and no group/other write access.\n' "$CONFIG" >&2
  exit 1
fi

source "$CONFIG"

[[ ${set_debug:-disabled} == enabled ]] && set -x

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    printf 'Another update run is already active.\n' >&2
    exit 1
  fi
fi

failures=()
updated_components=()
reboot_required=false

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

pushbullet_message() {
  local event=$1
  local message=$2
  local title="${HOSTNAME:-$(hostname)} - $event"

  [[ -n ${pushbullet_token:-} ]] || return 0

  curl --silent --show-error --fail --max-time 30 \
    --retry 2 --retry-delay 2 \
    --header "Access-Token: $pushbullet_token" \
    --data-urlencode 'type=note' \
    --data-urlencode "title=$title" \
    --data-urlencode "body=${message:0:9000}" \
    "$PUSHBULLET_URL" >/dev/null || {
      log 'Warning: Pushbullet notification failed.' >&2
      return 0
    }
}

record_failure() {
  failures+=("$1")
  log "Failed: $1" >&2
}

check_disk_space() {
  local threshold=${disk_space_threshold:-0}
  local available_kb required_kb

  [[ $threshold =~ ^[0-9]+$ ]] || {
    record_failure "Invalid disk_space_threshold: $threshold"
    return 1
  }
  (( threshold > 0 )) || return 0

  available_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
  [[ $available_kb =~ ^[0-9]+$ ]] || {
    record_failure 'Unable to determine free space on /.'
    return 1
  }

  required_kb=$((threshold * 1024 * 1024))
  if (( available_kb < required_kb )); then
    local available_gb=$((available_kb / 1024 / 1024))
    pushbullet_message 'Check disk space' \
      "Only ${available_gb} GB is available on /; the configured minimum is ${threshold} GB."
    record_failure "Insufficient disk space on / (${available_gb} GB available)"
    return 1
  fi
}

native_manager() {
  local manager
  for manager in apt-get dnf5 dnf yum zypper pacman; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s\n' "$manager"
      return 0
    fi
  done
  return 1
}

notify_updates() {
  local component=$1
  local list=$2
  local count

  count=$(grep -cve '^[[:space:]]*$' <<<"$list")
  (( count > 0 )) || return 0
  pushbullet_message 'Updates available' \
    "There are ${count} ${component} updates to install:\n${list}"
}

update_apt() {
  local list
  log 'Refreshing APT metadata.'
  apt-get update || return 1

  if ! list=$(apt-get --simulate dist-upgrade 2>/dev/null |
    awk '/^Inst / {old=$3; gsub(/[()]/, "", old); print $2, old, ">", $4}'); then
    return 1
  fi
  [[ -n $list ]] || {
    log 'APT is up to date.'
    return 0
  }

  notify_updates 'APT package' "$list"
  log 'Installing APT updates.'
  DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade || return 1
  updated_components+=('APT')

  if [[ ${cleanup_after_update:-true} == true ]]; then
    apt-get -y autoclean || return 1
  fi
  if [[ ${autoremove_packages:-false} == true ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y autoremove || return 1
  fi
  if [[ ${purge_residual_configs:-false} == true ]]; then
    mapfile -t residual < <(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null |
      awk '$1 == "rc" {print $2}')
    ((${#residual[@]} == 0)) || apt-get -y purge -- "${residual[@]}" || return 1
  fi
}

update_dnf() {
  local manager=$1
  local output rc list

  log "Checking ${manager} updates."
  if output=$($manager -q check-upgrade 2>&1); then
    rc=0
  else
    rc=$?
  fi
  case $rc in
    0)
      log "${manager} is up to date."
      return 0
      ;;
    100)
      list=$(sed -e '/^[[:space:]]*$/d' -e '/^Last metadata expiration check:/d' <<<"$output")
      ;;
    *)
      printf '%s\n' "$output" >&2
      return "$rc"
      ;;
  esac

  notify_updates "$manager package" "$list"
  log "Installing ${manager} updates."
  "$manager" -y upgrade || return 1
  updated_components+=("$manager")

  if [[ ${cleanup_after_update:-true} == true ]]; then
    "$manager" clean all || return 1
  fi
  if [[ ${autoremove_packages:-false} == true ]]; then
    "$manager" -y autoremove || return 1
  fi
}

update_zypper() {
  local list
  log 'Refreshing Zypper metadata.'
  zypper --non-interactive refresh || return 1
  if ! list=$(zypper --non-interactive list-updates 2>/dev/null |
    awk -F'|' '/^[[:space:]]*v[[:space:]]*\|/ {
      for (i=1; i<=NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      print $3, $4, ">", $5
    }'); then
    return 1
  fi
  [[ -n $list ]] || {
    log 'Zypper is up to date.'
    return 0
  }

  notify_updates 'Zypper package' "$list"
  log 'Installing Zypper updates.'
  zypper --non-interactive update || return 1
  updated_components+=('Zypper')

  if [[ ${cleanup_after_update:-true} == true ]]; then
    zypper --non-interactive clean --all || return 1
  fi
}

update_pacman() {
  local list=''

  if command -v checkupdates >/dev/null 2>&1; then
    local rc
    if list=$(checkupdates --nocolor 2>&1); then
      rc=0
    else
      rc=$?
    fi
    case $rc in
      0) ;;
      2)
        log 'Pacman is up to date.'
        return 0
        ;;
      *)
        printf '%s\n' "$list" >&2
        return "$rc"
        ;;
    esac
    notify_updates 'Pacman package' "$list"
  else
    log 'checkupdates is unavailable; Pacman will perform a direct full-system upgrade.'
  fi

  log 'Installing Pacman updates.'
  local pacman_output
  if ! pacman_output=$(pacman -Syu --noconfirm 2>&1); then
    printf '%s\n' "$pacman_output" >&2
    return 1
  fi
  printf '%s\n' "$pacman_output"
  if [[ -n $list ]] || ! grep -qi 'there is nothing to do' <<<"$pacman_output"; then
    updated_components+=('Pacman')
  fi

  if [[ ${cleanup_after_update:-true} == true ]] && command -v paccache >/dev/null 2>&1; then
    paccache -rk "${pacman_cache_versions:-3}" || return 1
    paccache -ruk0 || return 1
  fi
}

update_snap() {
  local list
  [[ ${update_snap:-true} == true ]] || return 0
  command -v snap >/dev/null 2>&1 || return 0

  if ! list=$(snap refresh --list 2>/dev/null | awk 'NR > 1 && NF {print $1, $2, $3}'); then
    return 1
  fi
  [[ -n $list ]] || {
    log 'Snap is up to date.'
    return 0
  }
  notify_updates 'Snap package' "$list"
  log 'Installing Snap updates.'
  snap refresh || return 1
  updated_components+=('Snap')

  if [[ ${cleanup_after_update:-true} == true ]]; then
    while read -r snapname revision; do
      [[ -n $snapname && -n $revision ]] || continue
      snap remove "$snapname" --revision="$revision" || return 1
    done < <(snap list --all | awk '$6 == "disabled" {print $1, $3}')
  fi
}

update_flatpak() {
  local list
  [[ ${update_flatpak:-true} == true ]] || return 0
  command -v flatpak >/dev/null 2>&1 || return 0

  if flatpak remote-ls --help 2>&1 | grep -q -- '--columns'; then
    if ! list=$(flatpak remote-ls --updates --columns=application,branch 2>/dev/null); then
      return 1
    fi
  else
    if ! list=$(flatpak remote-ls --updates 2>/dev/null); then
      return 1
    fi
  fi
  [[ -n $list ]] || {
    log 'Flatpak is up to date.'
    return 0
  }
  notify_updates 'Flatpak package' "$list"
  log 'Installing Flatpak updates.'
  flatpak update --noninteractive -y || return 1
  updated_components+=('Flatpak')

  if [[ ${cleanup_after_update:-true} == true ]]; then
    flatpak uninstall --unused --noninteractive -y || return 1
  fi
}


check_reboot_required() {
  local manager=$1 rc

  if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
    reboot_required=true
  elif [[ $manager == dnf5 ]]; then
    if dnf5 needs-restarting >/dev/null 2>&1; then
      reboot_required=false
    else
      rc=$?
      (( rc == 1 )) && reboot_required=true
    fi
  elif [[ $manager == dnf || $manager == yum ]]; then
    if "$manager" needs-restarting -r >/dev/null 2>&1; then
      reboot_required=false
    else
      rc=$?
      (( rc == 1 )) && reboot_required=true
    fi
  elif command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r >/dev/null 2>&1; then
      reboot_required=false
    else
      rc=$?
      (( rc == 1 )) && reboot_required=true
    fi
  fi

  [[ $reboot_required == true ]] || return 0

  if [[ ${reboot_after_update:-false} == true ]]; then
    pushbullet_message 'Reboot required' \
      'A reboot is required after the update. The system will reboot in 60 seconds.'
    sync
    sleep 60
    systemctl reboot || reboot
  else
    pushbullet_message 'Reboot required' \
      'A reboot is required after the update.'
  fi
}

main() {
  local manager

  check_disk_space || exit 1
  if ! manager=$(native_manager); then
    record_failure 'No supported native package manager was found.'
  else
    case $manager in
      apt-get) update_apt || record_failure 'APT update' ;;
      dnf5|dnf|yum) update_dnf "$manager" || record_failure "$manager update" ;;
      zypper) update_zypper || record_failure 'Zypper update' ;;
      pacman) update_pacman || record_failure 'Pacman update' ;;
    esac
  fi

  update_snap || record_failure 'Snap update'
  update_flatpak || record_failure 'Flatpak update'

  check_reboot_required "${manager:-none}"

  if ((${#failures[@]} > 0)); then
    local failure_text
    printf -v failure_text '%s\n' "${failures[@]}"
    pushbullet_message 'Update failed' "One or more update steps failed:\n${failure_text}"
    return 1
  fi

  if ((${#updated_components[@]} > 0)); then
    pushbullet_message 'Update completed' \
      "Updated: ${updated_components[*]}."
  fi
  log 'Update run completed successfully.'
}

main "$@"
