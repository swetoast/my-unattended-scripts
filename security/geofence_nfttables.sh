#!/usr/bin/env bash
# Rev. 1
# Geofence for countries
# Script made by Toast
# https://www.ipdeny.com/ipblocks/
# https://github.com/herrbischoff/country-ip-blocks/tree/master/ipv4
# Configuration
LAN=10.0.0.0/16
URL=https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4
TCP_PORTS=$(cat /etc/portblocker/blockport_tcp.conf)
UDP_PORTS=$(cat /etc/portblocker/blockport_udp.conf)
COUNTRY_CODES="se"

# Download IP ranges for the specified countries
get_file() {
    for COUNTRY_CODE in $COUNTRY_CODES; do
        IP_RANGE_FILE="/tmp/${COUNTRY_CODE}-ipv4.zone"
        wget --no-check-certificate -nv -c -t=10 $URL/$COUNTRY_CODE.cidr -O $IP_RANGE_FILE || exit 1

        # Add whitelist IPs and LAN to the IP range file
        cat /etc/portblocker/whitelist_dns.conf /etc/portblocker/whitelist_ip.conf | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" >> $IP_RANGE_FILE
        echo $LAN >> $IP_RANGE_FILE
    done
}

# Create nftables set and add the IP ranges to it
create_nftables_ipv4_range() {
    nft add table ip filter
    nft add chain ip filter input { type filter hook input priority 0 \; }
    nft add set ip filter country_ipv4_range { type ipv4_addr\; }

    for COUNTRY_CODE in $COUNTRY_CODES; do
        IP_RANGE_FILE="/tmp/${COUNTRY_CODE}-ipv4.zone"
        cat $IP_RANGE_FILE | xargs -I {} nft add element ip filter country_ipv4_range { {} }
    done
}

# Add nftables rules to allow traffic from the IP ranges and block all other traffic
create_rules() {
    local protocol=$1
    local ports=$2

    for PORT in $ports; do
        nft add rule ip filter input ip saddr @country_ipv4_range $protocol dport $PORT ct state new,established counter accept
        nft add rule ip filter input ip saddr != @country_ipv4_range $protocol dport $PORT ct state new,established counter drop
    done
}

# Check the status of the nftables service and restart it if necessary
check_service() {
    if systemctl is-enabled nftables.service >/dev/null 2>&1 && ! systemctl is-active nftables.service >/dev/null 2>&1; then
        systemctl restart nftables.service
    fi

    nft list set ip filter country_ipv4_range
    systemctl restart nftables.service
}

# Main script
get_file
create_nftables_ipv4_range
create_rules tcp $TCP_PORTS
create_rules udp $UDP_PORTS
check_service

# Clean up
rm /tmp/*-ipv4.zone
