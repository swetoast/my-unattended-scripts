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
| Value  |  |
| ------------- | ------------- |
| [export URL=](https://github.com/swetoast/my-unattended-scripts/blob/1a5afacaf69928b53162244251fc8974412687dd/security/geofence.sh#L10) | # set your url to the cidr ranges |
| [export LAN=](https://github.com/swetoast/my-unattended-scripts/blob/1a5afacaf69928b53162244251fc8974412687dd/security/geofence.sh#L6) | # your lan network |
| [export CC=](https://github.com/swetoast/my-unattended-scripts/blob/1a5afacaf69928b53162244251fc8974412687dd/security/geofence.sh#L15) | # your country code |

