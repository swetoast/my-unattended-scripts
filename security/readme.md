Config folder for Geofence
`/etc/portblocker/`

Files nessary in this folder
```
blockport_tcp.conf          # add your tcp ports here
blockport_udp.conf          # add your udp ports here
whitelist_ip.conf           # add cidr or single ips here
whitelist_dns.conf          # add domains to whitelist
```
Set values in the file
```
export URL=                 # set your url to the cidr ranges
export LAN=                 # your lan network
export CC=                  # your country code
```
