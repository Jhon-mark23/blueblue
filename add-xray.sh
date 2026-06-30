#!/bin/bash
# =========================================
# ADD VLESS USER - Simplified
# =========================================
# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# Root check
[ "${EUID}" -ne 0 ] && { echo -e "${RED}Run as root!${NC}"; exit 1; }

# Get IP
MYIP=$(wget -qO- ipv4.icanhazip.com)
echo "Checking VPS..."

# Load domain/IP
source /var/lib/ipvps.conf 2>/dev/null
if [[ "$IP" = "" ]]; then
    domain=$(cat /etc/xray/domain 2>/dev/null || echo "$MYIP")
else
    domain=$IP
fi
[ -z "$domain" ] && domain="$MYIP"

# Get ports from install log
tls="$(grep -w "Vless WS TLS" ~/log-install.txt 2>/dev/null | cut -d: -f2 | sed 's/ //g')"
none="$(grep -w "Vless WS none TLS" ~/log-install.txt 2>/dev/null | cut -d: -f2 | sed 's/ //g')"
[ -z "$tls" ] && tls="443"
[ -z "$none" ] && none="80"

# Username input with duplicate check
until [[ $user =~ ^[a-zA-Z0-9_]+$ && ${CLIENT_EXISTS} == '0' ]]; do
    clear
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\E[44;1;39m        Add VLESS Account        \E[0m"
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    
    read -rp "User: " -e user
    CLIENT_EXISTS=$(grep -w "$user" /etc/xray/config.json | wc -l)
    
    if [[ ${CLIENT_EXISTS} == '1' ]]; then
        clear
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "\E[44;1;39m        Add VLESS Account        \E[0m"
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo ""
        echo -e "${RED}A client with this name already exists!${NC}"
        echo ""
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        read -n 1 -s -r -p "Press any key to continue..."
    fi
done

# Generate UUID and set expiry
uuid=$(cat /proc/sys/kernel/random/uuid)
read -p "Expired (days): " masaaktif
exp=$(date -d "$masaaktif days" +"%Y-%m-%d")

# Insert into Xray config (WebSocket + gRPC)
sed -i '/#vless$/a\#& '"$user $exp"'\
},{"id": "'""$uuid""'","email": "'""$user""'"' /etc/xray/config.json

sed -i '/#vlessgrpc$/a\#& '"$user $exp"'\
},{"id": "'""$uuid""'","email": "'""$user""'"' /etc/xray/config.json

# Generate VLESS links
vlesslink1="vless://${uuid}@${domain}:${tls}?path=/vless&security=tls&encryption=none&type=ws&host=${domain}&sni=${domain}&allowInsecure=1#${user}"
vlesslink2="vless://${uuid}@${domain}:${none}?path=/vless&security=none&encryption=none&type=ws&host=${domain}#${user}"
vlesslink3="vless://${uuid}@${domain}:${tls}?mode=gun&security=tls&encryption=none&type=grpc&serviceName=vless-grpc&sni=${domain}&allowInsecure=1#VLESS_GRPC_${user}"

# Restart Xray
systemctl restart xray
sleep 2

# Create TXT config file for download
mkdir -p /home/vps/public_html
cat > /home/vps/public_html/vless-${user}.txt <<EOF
============================================================
              VLESS ACCOUNT
============================================================
Username        : ${user}
Domain          : ${domain}
Port TLS        : ${tls}
Port none TLS   : ${none}
UUID            : ${uuid}
Encryption      : none
Network         : ws / grpc
WS Path         : /vless
gRPC Service    : vless-grpc
Expired         : ${exp}
============================================================
Link TLS (WS)   : ${vlesslink1}
Link none TLS   : ${vlesslink2}
Link gRPC       : ${vlesslink3}
============================================================
EOF

# Create JSON config file
cat > /home/vps/public_html/vless-${user}.json <<EOF
{
  "remarks": "VLESS ${user}",
  "domain": "${domain}",
  "protocol": "vless",
  "uuid": "${uuid}",
  "tls_port": ${tls},
  "ntls_port": ${none},
  "encryption": "none",
  "network": "ws",
  "ws_path": "/vless",
  "grpc_service": "vless-grpc",
  "expired": "${exp}",
  "allow_insecure": true,
  "link_tls_ws": "${vlesslink1}",
  "link_ntls_ws": "${vlesslink2}",
  "link_grpc": "${vlesslink3}"
}
EOF

# Display result
clear
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo -e "\E[44;1;39m          VLESS Account Created           \E[0m" | tee -a /etc/log-create-vless.log
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo -e " Remarks       : ${GREEN}${user}${NC}" | tee -a /etc/log-create-vless.log
echo -e " Domain        : ${domain}" | tee -a /etc/log-create-vless.log
echo -e " Port TLS      : ${tls}" | tee -a /etc/log-create-vless.log
echo -e " Port none TLS : ${none}" | tee -a /etc/log-create-vless.log
echo -e " UUID          : ${uuid}" | tee -a /etc/log-create-vless.log
echo -e " Encryption    : none" | tee -a /etc/log-create-vless.log
echo -e " Network       : ws / grpc" | tee -a /etc/log-create-vless.log
echo -e " WS Path       : /vless" | tee -a /etc/log-create-vless.log
echo -e " gRPC Service  : vless-grpc" | tee -a /etc/log-create-vless.log
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo -e " ${CYAN}Link TLS (WS):${NC}" | tee -a /etc/log-create-vless.log
echo -e " ${vlesslink1}" | tee -a /etc/log-create-vless.log
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo -e " ${CYAN}Link none TLS:${NC}" | tee -a /etc/log-create-vless.log
echo -e " ${vlesslink2}" | tee -a /etc/log-create-vless.log
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo -e " ${CYAN}Link gRPC:${NC}" | tee -a /etc/log-create-vless.log
echo -e " ${vlesslink3}" | tee -a /etc/log-create-vless.log
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo -e " ${CYAN}Config TXT:${NC} http://${domain}:81/vless-${user}.txt" | tee -a /etc/log-create-vless.log
echo -e " ${CYAN}Config JSON:${NC} http://${domain}:81/vless-${user}.json" | tee -a /etc/log-create-vless.log
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo -e " Expired On    : ${RED}${exp}${NC}" | tee -a /etc/log-create-vless.log
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" | tee -a /etc/log-create-vless.log
echo "" | tee -a /etc/log-create-vless.log

read -n 1 -s -r -p "Press any key to back to menu"