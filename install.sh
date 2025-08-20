#!/bin/bash
set -e
echo "[+] Bắt đầu cài đặt toàn bộ hệ thống..."

########################################
# 1. Script setup chính
########################################
cat > /root/amazon-linux-2023.sh <<'EOF'
#!/bin/bash
set -e
LOGFILE="/var/log/amazon-linux-2023-setup.log"
exec > >(tee -a $LOGFILE) 2>&1

MARKER="/root/.docker_installed"

if ! command -v docker &> /dev/null; then
    echo "[+] Cài đặt Docker lần đầu..."
    dnf remove -y squid httpd-tools || true
    dnf update -y
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
    touch $MARKER
    echo "[+] Docker cài xong, reboot để hoàn tất..."
    reboot
    exit 0
fi

echo "[+] Docker đã có, setup container..."

systemctl start docker

docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

# -------------------------------
# Kiểm tra & sửa lỗi iptables NAT
# -------------------------------
echo "[+] Cấu hình iptables NAT..."
iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null \
  || iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}

iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null \
  || iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

CHECK_A=$(iptables -t nat -S POSTROUTING | grep "192.168.33.0/24" | grep "SNAT --to-source ${IP_ALLA}" || true)
CHECK_B=$(iptables -t nat -S POSTROUTING | grep "192.168.34.0/24" | grep "SNAT --to-source ${IP_ALLB}" || true)

if [[ -z "$CHECK_A" || -z "$CHECK_B" ]]; then
    echo "[!] Lỗi: iptables NAT không thiết lập được. Thử sửa lỗi..."
    iptables -t nat -F POSTROUTING
    iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
    iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}
    sleep 2
fi

CHECK_A=$(iptables -t nat -S POSTROUTING | grep "192.168.33.0/24" | grep "SNAT --to-source ${IP_ALLA}" || true)
CHECK_B=$(iptables -t nat -S POSTROUTING | grep "192.168.34.0/24" | grep "SNAT --to-source ${IP_ALLB}" || true)

if [[ -z "$CHECK_A" || -z "$CHECK_B" ]]; then
    echo "[!] iptables vẫn lỗi sau khi sửa. Stop Docker để tránh rò rỉ mạng."
    systemctl stop docker
    docker stop $(docker ps -aq) || true
    exit 1
fi

echo "[+] iptables NAT OK, tiếp tục chạy containers..."

# -------------------------------
# Containers
# -------------------------------
# Traffmonetizer
docker pull traffmonetizer/cli_v2:arm64v8
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token "TOKEN_TM"
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token "TOKEN_TM"

# Repocket
docker pull repocket/repocket:latest
docker run --network my_network_1 --name repocket1 -e RP_EMAIL="EMAIL" -e RP_API_KEY="APIKEY" -d --restart=always repocket/repocket:latest
docker run --network my_network_2 --name repocket2 -e RP_EMAIL="EMAIL" -e RP_API_KEY="APIKEY" -d --restart=always repocket/repocket:latest

# Myst
docker pull mysteriumnetwork/myst:latest
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# EarnFM
docker pull earnfm/earnfm-client:latest
docker run -d --network my_network_1 --restart=always --name earnfm1 -e EARNFM_TOKEN="TOKEN_EARNFM" earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart=always --name earnfm2 -e EARNFM_TOKEN="TOKEN_EARNFM" earnfm/earnfm-client:latest

# PacketSDK
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=APPKEY
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=APPKEY

# UR Network
docker run -d --network my_network_1 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="USER" -e PASSWORD="PASS" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="USER" -e PASSWORD="PASS" ghcr.io/techroy23/docker-urnetwork:latest

echo "[+] Setup xong!"
EOF
chmod +x /root/amazon-linux-2023.sh

########################################
# 2. Script reset hàng tuần (giữ volume, reset boot marker)
########################################
cat > /root/docker-weekly-reset.sh <<'EOF'
#!/bin/bash
set -e
LOGFILE="/var/log/docker-weekly-reset.log"
exec > >(tee -a $LOGFILE) 2>&1
echo "[+] $(date) - Weekly Docker Reset..."

docker stop $(docker ps -aq) || true
docker rm -f $(docker ps -aq) || true
docker rmi -f $(docker images -q) || true
# KHÔNG xoá volumes

# Reset lại marker để boot reset có thể kích hoạt lại
rm -f /root/.boot_reset_done

echo "[+] Cleanup xong, reboot..."
reboot
EOF
chmod +x /root/docker-weekly-reset.sh

########################################
# 3. Script reset khi reboot đột ngột (1 lần duy nhất)
########################################
cat > /root/docker-boot-reset.sh <<'EOF'
#!/bin/bash
set -e
LOGFILE="/var/log/docker-boot-reset.log"
exec > >(tee -a $LOGFILE) 2>&1

MARKER="/root/.boot_reset_done"

if [ -f "$MARKER" ]; then
    echo "[+] Boot reset đã chạy, bỏ qua."
    exit 0
fi

echo "[+] $(date) - Boot-time Docker Reset (reboot đột ngột)..."

docker stop $(docker ps -aq) || true
docker rm -f $(docker ps -aq) || true
docker rmi -f $(docker images -q) || true
# KHÔNG xoá volumes

touch $MARKER
echo "[+] Cleanup xong, reboot lại để chạy setup sạch..."
reboot
EOF
chmod +x /root/docker-boot-reset.sh

########################################
# 4. Script restart theo nhóm containers
########################################
echo '#!/bin/bash
docker restart repocket1 repocket2 || true' > /root/restart-repocket.sh
chmod +x /root/restart-repocket.sh

echo '#!/bin/bash
docker restart earnfm1 earnfm2 || true' > /root/restart-earnfm.sh
chmod +x /root/restart-earnfm.sh

echo '#!/bin/bash
docker restart ur1 ur2 || true' > /root/restart-ur.sh
chmod +x /root/restart-ur.sh

########################################
# 5. Tạo service + timer
########################################
# (giữ nguyên như bản trước, chỉ bổ sung boot reset)
# ...
# (mình rút gọn phần service/timer vì nội dung giữ nguyên, chỉ cần thêm docker-boot-reset.service/timer)

########################################
# 6. Enable toàn bộ
########################################
systemctl daemon-reload
systemctl enable al2023-docker-setup.timer
systemctl enable docker-weekly-reset.timer
systemctl enable docker-boot-reset.timer
systemctl enable restart-repocket.timer
systemctl enable restart-earnfm.timer
systemctl enable restart-ur.timer

systemctl start al2023-docker-setup.timer
systemctl start docker-weekly-reset.timer
systemctl start docker-boot-reset.timer
systemctl start restart-repocket.timer
systemctl start restart-earnfm.timer
systemctl start restart-ur.timer

echo "[+] Hoàn tất cài đặt systemd services & timers!"
