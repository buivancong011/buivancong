IP_ALLA=$(/sbin/ip -4 -o addr show scope global dynamic eth0 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global secondary eth0 | awk '{gsub(/\/.*/,"",$4); print $4}')

IP_ALLA_ARRAY=($IP_ALLA)
IP_ALLB_ARRAY=($IP_ALLB)


for IP_ADDRA in ${IP_ALLA_ARRAY[@]}; do
iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ADDRA}
for IP_ADDRB in ${IP_ALLB_ARRAY[@]}; do
iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ADDRB}
done
done
echo "Done"

