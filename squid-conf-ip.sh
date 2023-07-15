#!/bin/bash
# Author: admin@serverOk.in
# Web: https://www.serverok.in
IP_ALLA=$(/sbin/ip -4 -o addr show scope global dynamic eth0 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global secondary eth0 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLC=$(/sbin/ip -6 -o addr show scope global dynamic eth0 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLD=$(/sbin/ip -6 -o addr show scope global dynamic eth0 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLA_ARRAY=($IP_ALLA)
IP_ALLB_ARRAY=($IP_ALLB)
IP_ALLC_ARRAY=($IP_ALLC)
IP_ALLD_ARRAY=($IP_ALLD)
for IP_ADDRC in ${IP_ALLC_ARRAY[@]}; do
IPSVA=($IP_ADDRC)
SQUID_CONFIG="\n"
for IP_ADDRA in ${IP_ALLA_ARRAY[@]}; do
for IP_ADDRB in ${IP_ALLB_ARRAY[@]}; do
    ACL_NAME="proxy_ip_${IP_ADDRA//\./_}"
    SQUID_CONFIG+="acl ${ACL_NAME}  myip ${IP_ADDRA}\n"
    SQUID_CONFIG+="tcp_outgoing_address ${IP_ADDRA} ${ACL_NAME}\n\n"
    SQUID_CONFIG+="tcp_outgoing_address ${IPSVA} ${ACL_NAME}\n\n"
    ACL_NAME="proxy_ip_${IP_ADDRB//\./_}"
    SQUID_CONFIG+="acl ${ACL_NAME}  myip ${IP_ADDRB}\n"
    SQUID_CONFIG+="tcp_outgoing_address ${IP_ADDRB} ${ACL_NAME}\n\n"
    SQUID_CONFIG+="tcp_outgoing_address ${IP_ALLD_ARRAY} ${ACL_NAME}\n\n"
done
done
done
echo "Updating squid config"
echo -e $SQUID_CONFIG >> /etc/squid/squid.conf
echo "Restarting squid..."
systemctl restart squid
echo "Done"

