IP_ALL=$(/sbin/ip -4 -o addr show scope global | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLS=$(/sbin/ip -6 -o addr show scope global | awk '{gsub(/\/.*/,"",$4); print $4}')

IP_ALL_ARRAY=($IP_ALL)
IP_ALLL_ARRAY=($IP_ALLS)
for IP_ADDRS in ${IP_ALLL_ARRAY[@]}; do

SQUID_CONFIG="\n"

for IP_ADDR in ${IP_ALL_ARRAY[@]}; do
    ACL_NAME="proxy_ip_${IP_ADDR//\./_}"
    SQUID_CONFIG+="acl ${ACL_NAME}  myip ${IP_ADDR}\n"
    SQUID_CONFIG+="tcp_outgoing_address ${IP_ADDR} ${ACL_NAME}\n\n"
done
SQUID_CONFIG+="tcp_outgoing_address ${IP_ADDRS} ${ACL_NAME}\n\n"
done
echo "Updating squid config"

echo -e $SQUID_CONFIG >> /etc/squid/squid.conf

echo "Restarting squid..."

systemctl restart squid

echo "Done"
