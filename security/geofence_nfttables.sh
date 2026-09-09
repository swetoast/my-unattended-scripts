#!/usr/bin/env bash
# Rev. 2
# Country geofence for selected inbound IPv4 TCP and UDP ports
# Script made by Toast

set -u
set -o pipefail
umask 077
export LC_ALL=C
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

LAN='10.0.0.0/16'
COUNTRY_CODES='se'
BASE_URL='https://herrbischoff.com/code/me/country-ip-blocks/raw/branch/master/ipv4'
TCP_PORT_FILE='/etc/portblocker/blockport_tcp.conf'
UDP_PORT_FILE='/etc/portblocker/blockport_udp.conf'
WHITELIST_FILES=(
  '/etc/portblocker/whitelist_dns.conf'
  '/etc/portblocker/whitelist_ip.conf'
)
NFT_MAIN='/etc/nftables.conf'
NFT_DIR='/etc/nftables.d'
NFT_FILE="$NFT_DIR/toast-geofence.nft"
LOCK_FILE='/run/lock/toast-geofence.lock'
TABLE_NAME='toast_geofence'

if (( EUID != 0 )); then
  exec sudo -- "$0" "$@"
fi

for command in nft awk sed grep sort mktemp install find; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  }
done

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    printf 'Another geofence update is already running.\n' >&2
    exit 1
  fi
fi

WORK_DIR=$(mktemp -d /tmp/toast-geofence.XXXXXX)
cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'Geofence update failed: %s\n' "$1" >&2
  exit 1
}

download() {
  local url=$1
  local output=$2

  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location \
      --connect-timeout 20 --max-time 120 \
      --retry 3 --retry-delay 2 \
      --output "$output" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --quiet --timeout=20 --tries=3 --output-document="$output" "$url"
  else
    fail 'Neither curl nor wget is installed.'
  fi
}

normalize_ports() {
  local source=$1
  local output=$2

  [[ -f $source ]] || fail "Missing port file: $source"

  awk '
    {
      sub(/#.*/, "")
      gsub(/,/, " ")
      for (i = 1; i <= NF; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 1 || $i > 65535) {
          printf "Invalid port in %s: %s\\n", FILENAME, $i > "/dev/stderr"
          bad = 1
        } else {
          print $i
        }
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$source" | sort -n -u >"$output" || fail "Invalid port configuration in $source"
}

extract_whitelist_ipv4() {
  local output=$1
  local file

  : >"$output"
  for file in "${WHITELIST_FILES[@]}"; do
    [[ -f $file ]] || continue
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?' "$file" >>"$output" || true
  done
}

validate_ipv4_list() {
  local source=$1
  local output=$2

  awk '
    function valid_ipv4(value, address, prefix, octets, count, i) {
      address = value
      prefix = ""
      if (index(value, "/")) {
        split(value, parts, "/")
        if (length(parts) != 2 || parts[2] !~ /^[0-9]+$/ || parts[2] > 32) return 0
        address = parts[1]
        prefix = "/" parts[2]
      }
      count = split(address, octets, ".")
      if (count != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (octets[i] !~ /^[0-9]+$/ || octets[i] > 255) return 0
      }
      return 1
    }
    /^[[:space:]]*($|#)/ { next }
    {
      value = $1
      sub(/\r$/, "", value)
      if (!valid_ipv4(value)) {
        printf "Invalid IPv4 address or CIDR in %s: %s\\n", FILENAME, value > "/dev/stderr"
        bad = 1
      } else {
        print value
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$source" >"$output" || fail "Invalid IPv4 data in $source"
}

join_nft_elements() {
  local source=$1
  awk 'BEGIN { first = 1 } NF { if (!first) printf ", "; printf "%s", $0; first = 0 } END { print "" }' "$source"
}

normalize_ports "$TCP_PORT_FILE" "$WORK_DIR/tcp-ports"
normalize_ports "$UDP_PORT_FILE" "$WORK_DIR/udp-ports"

if [[ ! -s $WORK_DIR/tcp-ports && ! -s $WORK_DIR/udp-ports ]]; then
  fail 'No TCP or UDP ports are configured.'
fi

: >"$WORK_DIR/downloaded-ranges"
for country_code in $COUNTRY_CODES; do
  [[ $country_code =~ ^[a-z]{2}$ ]] || fail "Invalid country code: $country_code"
  country_file="$WORK_DIR/${country_code}.cidr"
  download "$BASE_URL/${country_code}.cidr" "$country_file" || fail "Unable to download ranges for $country_code"
  [[ -s $country_file ]] || fail "Downloaded range file for $country_code is empty"
  validate_ipv4_list "$country_file" "$WORK_DIR/${country_code}.validated"
  cat "$WORK_DIR/${country_code}.validated" >>"$WORK_DIR/downloaded-ranges"
done

extract_whitelist_ipv4 "$WORK_DIR/whitelist-raw"
validate_ipv4_list "$WORK_DIR/whitelist-raw" "$WORK_DIR/whitelist"

{
  printf '%s\n' '127.0.0.0/8'
  printf '%s\n' "$LAN"
  cat "$WORK_DIR/downloaded-ranges"
  cat "$WORK_DIR/whitelist"
} | sort -u >"$WORK_DIR/allowed-ipv4"

[[ -s $WORK_DIR/allowed-ipv4 ]] || fail 'The final allowed IPv4 set is empty.'

allowed_elements=$(join_nft_elements "$WORK_DIR/allowed-ipv4")
tcp_elements=$(join_nft_elements "$WORK_DIR/tcp-ports")
udp_elements=$(join_nft_elements "$WORK_DIR/udp-ports")

cat >"$WORK_DIR/geofence.nft" <<EOF_NFT
table ip $TABLE_NAME {
  set country_allow4 {
    type ipv4_addr
    flags interval
    auto-merge
    elements = { $allowed_elements }
  }

  set tcp_ports {
    type inet_service
EOF_NFT
if [[ -s $WORK_DIR/tcp-ports ]]; then
  printf '    elements = { %s }\n' "$tcp_elements" >>"$WORK_DIR/geofence.nft"
fi
cat >>"$WORK_DIR/geofence.nft" <<EOF_NFT
  }

  set udp_ports {
    type inet_service
EOF_NFT
if [[ -s $WORK_DIR/udp-ports ]]; then
  printf '    elements = { %s }\n' "$udp_elements" >>"$WORK_DIR/geofence.nft"
fi
cat >>"$WORK_DIR/geofence.nft" <<EOF_NFT
  }

  chain input {
    type filter hook input priority -10; policy accept;
EOF_NFT
if [[ -s $WORK_DIR/tcp-ports ]]; then
  printf '    ip saddr != @country_allow4 tcp dport @tcp_ports counter drop comment "Toast country geofence TCP"\n' >>"$WORK_DIR/geofence.nft"
fi
if [[ -s $WORK_DIR/udp-ports ]]; then
  printf '    ip saddr != @country_allow4 udp dport @udp_ports counter drop comment "Toast country geofence UDP"\n' >>"$WORK_DIR/geofence.nft"
fi
cat >>"$WORK_DIR/geofence.nft" <<'EOF_NFT'
  }
}
EOF_NFT

# Create a temporary placeholder so replacement works for both first and later runs.
nft list table ip "$TABLE_NAME" >/dev/null 2>&1 || nft add table ip "$TABLE_NAME" || fail 'Unable to create the nftables table placeholder.'

{
  printf 'delete table ip %s\n' "$TABLE_NAME"
  cat "$WORK_DIR/geofence.nft"
} >"$WORK_DIR/apply.nft"

nft --check --file "$WORK_DIR/apply.nft" || fail 'Generated nftables rules failed validation.'
nft --file "$WORK_DIR/apply.nft" || fail 'Unable to apply the nftables rules.'

install -d -m 0755 "$NFT_DIR"
install -m 0644 "$WORK_DIR/geofence.nft" "$NFT_FILE"

if [[ ! -f $NFT_MAIN ]]; then
  printf '#!/usr/sbin/nft -f\n\nflush ruleset\n\ninclude "%s/*.nft"\n' "$NFT_DIR" >"$WORK_DIR/nftables.conf"
  install -m 0644 "$WORK_DIR/nftables.conf" "$NFT_MAIN"
elif ! grep -Fq 'include "/etc/nftables.d/*.nft"' "$NFT_MAIN"; then
  cp -p -- "$NFT_MAIN" "$WORK_DIR/nftables.conf.backup"
  printf '\ninclude "%s/*.nft"\n' "$NFT_DIR" >>"$NFT_MAIN"
  if ! nft --check --file "$NFT_MAIN"; then
    cp -p -- "$WORK_DIR/nftables.conf.backup" "$NFT_MAIN"
    fail 'The nftables include could not be added safely; the original nftables.conf was restored.'
  fi
fi

nft list table ip "$TABLE_NAME" >/dev/null 2>&1 || fail 'The geofence table is not loaded after installation.'

printf 'Geofence updated: %s allowed IPv4 ranges, %s TCP ports, %s UDP ports.\n' \
  "$(wc -l <"$WORK_DIR/allowed-ipv4")" \
  "$(wc -l <"$WORK_DIR/tcp-ports")" \
  "$(wc -l <"$WORK_DIR/udp-ports")"
