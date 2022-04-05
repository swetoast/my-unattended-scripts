#!/usr/bin/env bash
# Rev. 1
# Geofence for countries
# Script made by Toast
# Set Lan network
export LAN=10.0.0.0/16
# Alternative Country IP Blocks
# https://www.ipdeny.com/ipblocks/
# https://github.com/herrbischoff/country-ip-blocks/tree/master/ipv4
export URL=https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4
# Set ports that should be limited here
export PPTCP=$(cat /etc/portblocker/blockport_tcp.conf)
export PPUDP=$(cat /etc/portblocker/blockport_udp.conf)
# Set countries that should be allowed here
export CC="
se
"

get_file (){
for COUNTYCODE in $CC; do
wget --no-check-certificate -nv -c -t=10 $URL/$COUNTYCODE.cidr -O /tmp/countries-ipv4.zone

for DOMAIN in /etc/portblocker/whitelist.conf; do
/usr/bin/dig "$DOMAIN" | /usr/bin/grep "$DOMAIN" | /usr/bin/grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" >> /tmp/countries-ipv4.zone
done

for IP in /etc/portblocker/whitelist_ip.conf; do
/usr/bin/echo "$IP" >> /tmp/countries-ipv4.zone
done

/usr/bin/echo $LAN >> /tmp/countries-ipv4.zone

done
}

setting_device_variables () {
case $(/usr/sbin/ipset -v | /usr/bin/grep -o "v[4,6,7]") in
v7) MATCH_SET='--match-set'; CREATE='create'; ADD='add'; SWAP='swap'; IPHASH='hash:ip'; NETHASH='hash:net'; INET4='family inet'; DESTROY='destroy'; INET6='family inet6'; LIST='list'; HASHSIZE='hashsize 65536'; MAXELEM='maxelem 131072' ;;
v6) MATCH_SET='--match-set'; CREATE='create'; ADD='add'; SWAP='swap'; IPHASH='hash:ip'; NETHASH='hash:net'; INET4='family inet'; DESTROY='destroy'; INET6='family inet6'; LIST='list'; HASHSIZE='hashsize 65536'; MAXELEM='maxelem 131072' ;;
v4) MATCH_SET='--set'; CREATE='--create'; ADD='--add'; SWAP='--swap'; IPHASH='iphash'; NETHASH='nethash'; DESTROY='--destroy' INET6=''; LIST='--list'; HASHSIZE=''; MAXELEM='' ;;
 *) exit 1 ;;
esac; }

create_ipset_ipv4_range () {
if [ ! -f /tmp/countries-ipv4.zone ]; then get_file; fi
if [ "$(/usr/sbin/ipset -L | /usr/bin/grep -coE "country_ipv4_range$")" -eq 1 ]
then /usr/bin/nice -n 15 /usr/sbin/ipset $CREATE country_ipv4_update_range $NETHASH $INET4
     cat /tmp/countries-ipv4.zone | /usr/bin/nice -n 15 /usr/bin/xargs -I {} /usr/sbin/ipset $ADD country_ipv4_update_range {}
     /usr/bin/nice -n 15 /usr/sbin/ipset $SWAP country_ipv4_update_range country_ipv4_range
     /usr/bin/nice -n 15 /usr/sbin/ipset $DESTROY country_ipv4_update_range
else /usr/bin/nice -n 15 /usr/sbin/ipset $CREATE country_ipv4_range $NETHASH $INET4
     cat /tmp/countries-ipv4.zone | /usr/bin/nice -n 15 /usr/bin/xargs -I {} /usr/sbin/ipset $ADD country_ipv4_range {}
fi }

create_block () {
    for PORT in $PPTCP; do
    TCP=$(/usr/sbin/iptables -L INPUT | /usr/bin/grep "tcp" | /usr/bin/grep "country_ipv4_range" | wc -l)

    if [ "$TCP" -eq "0" ]; then
    /usr/sbin/iptables -A INPUT -m set $MATCH_SET country_ipv4_range src,dst -p tcp --dport $PORT -m state --state NEW,ESTABLISHED -j ACCEPT
    /usr/sbin/iptables -A INPUT -m set ! $MATCH_SET country_ipv4_range src,dst -p tcp --dport $PORT -m state --state NEW,ESTABLISHED -j DROP
fi
done

for PORT in $PPUDP; do
UDP=$(/usr/sbin/iptables -L INPUT | /usr/bin/grep "udp" | /usr/bin/grep "country_ipv4_range" | wc -l)

if [ "$UDP" -eq "0" ]; then
    /usr/sbin/iptables -A INPUT -m set $MATCH_SET country_ipv4_range src,dst -p udp --dport $PORT -m state --state NEW,ESTABLISHED -j ACCEPT
    /usr/sbin/iptables -A INPUT -m set ! $MATCH_SET country_ipv4_range src,dst -p udp --dport $PORT -m state --state NEW,ESTABLISHED -j DROP
fi
done
}

check_service () {
if systemctl is-enabled /usr/sbin/iptables.service >/dev/null 2>&1 && ! systemctl is-active /usr/sbin/iptables.service >/dev/null 2>&1
   then systemctl restart /usr/sbin/iptables.service; fi
rm /tmp/countries-ipv4.zone
/usr/sbin/ipset -L | /usr/bin/grep "Number of entries"
systemctl restart netfilter-persistent.service
}

check_service () {
if systemctl is-enabled /usr/sbin/iptables.service >/dev/null 2>&1 && ! systemctl is-active /usr/sbin/iptables.service >/dev/null 2>&1
   then systemctl restart /usr/sbin/iptables.service; fi
rm /tmp/countries-ipv4.zone
/usr/sbin/ipset -L | /usr/bin/grep "Number of entries"
systemctl restart netfilter-persistent.service
}

get_file
setting_device_variables
create_ipset_ipv4_range
create_block
check_service
