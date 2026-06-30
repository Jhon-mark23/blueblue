#!/bin/bash
# =========================================
# XRAY MULTI-PROTOCOL USER MANAGEMENT
# =========================================
# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# Root check
[ "${EUID}" -ne 0 ] && { echo -e "${RED}Run as root!${NC}"; exit 1; }

# Load domain
source /var/lib/scrz-prem/ipvps.conf 2>/dev/null
if [[ "$IP" = "" ]]; then
    domain=$(cat /etc/xray/domain 2>/dev/null || echo "")
    [ -z "$domain" ] && domain=$IP
else
    domain=$IP
fi

# Ports (fallback if log-install.txt missing)
tls_port=$(grep -oP '(?<=XRAY.*TLS : )\d+' /root/log-install.txt 2>/dev/null | head -1)
[ -z "$tls_port" ] && tls_port=443
ntls_port=$(grep -oP '(?<=XRAY.*None TLS : )\d+' /root/log-install.txt 2>/dev/null | head -1)
[ -z "$ntls_port" ] && ntls_port=80

# Functions
add_protocol() {
    local proto="$1"       # vless / vmess / trojan / shadowsocks / socks
    local marker="$2"      # placeholder in config (e.g. #vless)
    local path_ws="$3"     # WebSocket path
    local grpc_svc="$4"    # gRPC service name

    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}   ADD ${proto^^} USER${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    read -p "Username : " user
    [ -z "$user" ] && { echo -e "${RED}Username empty!${NC}"; return 1; }
    if grep -q "\"email\": \"$user\"" /etc/xray/config.json; then
        echo -e "${RED}User already exists!${NC}"
        return 1
    fi

    local uuid="" password=""
    if [[ "$proto" == "socks" ]]; then
        read -p "Password : " password
        [ -z "$password" ] && { echo -e "${RED}Password empty!${NC}"; return 1; }
    elif [[ "$proto" == "shadowsocks" ]]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
        password="$uuid"
        cipher="aes-128-gcm"
    else
        uuid=$(cat /proc/sys/kernel/random/uuid)
    fi

    read -p "Expired (days) : " days
    ! [[ "$days" =~ ^[0-9]+$ ]] && { echo -e "${RED}Invalid days!${NC}"; return 1; }
    exp=$(date -d "$days days" +"%Y-%m-%d")

    # Build client entry
    case $proto in
        vless) client="{\"id\": \"$uuid\", \"email\": \"$user\"}" ;;
        vmess) client="{\"id\": \"$uuid\", \"alterId\": 0, \"email\": \"$user\"}" ;;
        trojan) client="{\"password\": \"$uuid\", \"email\": \"$user\"}" ;;
        shadowsocks) client="{\"password\": \"$uuid\", \"method\": \"$cipher\", \"email\": \"$user\"}" ;;
        socks) client="{\"user\": \"$user\", \"pass\": \"$password\"}" ;;
    esac

    # Insert into config
    sed -i "/${marker}$/a\\${client}," /etc/xray/config.json
    # Also insert into the corresponding gRPC marker if needed
    if [[ "$proto" != "socks" ]]; then
        local grpc_marker="${marker}grpc"
        sed -i "/${grpc_marker}$/a\\${client}," /etc/xray/config.json
    fi

    systemctl restart xray
    sleep 2

    # Generate config file
    mkdir -p /home/vps/public_html
    local outfile="/home/vps/public_html/${proto}-${user}.txt"
    cat > "$outfile" <<EOF
============================================================
   XRAY ${proto^^} ACCOUNT
============================================================
Username  : $user
Domain    : $domain
Protocol  : $proto
UUID/Pass : ${uuid:-$password}
TLS Port  : $tls_port
NTLS Port : $ntls_port
WS Path   : /${path_ws}
gRPC Svc  : ${grpc_svc}
Expired   : $exp
============================================================
EOF

    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}   ${proto^^} ACCOUNT CREATED${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Username  : ${GREEN}$user${NC}"
    echo -e "Domain    : $domain"
    echo -e "UUID/Pass : ${uuid:-$password}"
    echo -e "Port TLS  : $tls_port"
    echo -e "Path WS   : /${path_ws}"
    echo -e "gRPC      : ${grpc_svc}"
    echo -e "Expired   : $exp"
    echo -e "Config file: http://${domain}:81/${proto}-${user}.txt"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

delete_user() {
    read -p "Username to delete: " user
    [ -z "$user" ] && { echo -e "${RED}Empty!${NC}"; return 1; }
    sed -i "/\"email\": \"$user\"/d" /etc/xray/config.json
    sed -i "/\"user\": \"$user\"/d" /etc/xray/config.json
    # Remove trailing commas
    sed -i ':a;N;$!ba;s/,\n\s*]/\n]/g' /etc/xray/config.json
    rm -f /home/vps/public_html/*-${user}.txt
    systemctl restart xray
    echo -e "${GREEN}User $user deleted.${NC}"
}

list_users() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}   CURRENT XRAY USERS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    grep -o '"email": "[^"]*"\|"user": "[^"]*"' /etc/xray/config.json | while read line; do
        name=$(echo "$line" | cut -d'"' -f4)
        echo -e "  ${GREEN}•${NC} $name"
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Menu
clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}   XRAY MULTI-PROTOCOL MANAGER${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " 1. Add VLESS"
echo -e " 2. Add VMess"
echo -e " 3. Add Trojan"
echo -e " 4. Add Shadowsocks"
echo -e " 5. Add Socks"
echo -e " 6. Delete User"
echo -e " 7. List Users"
echo -e " 8. Back to Main Menu"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -p "Select [1-8]: " opt

case $opt in
    1) add_protocol "vless" "#vless" "vless" "vless-grpc" ;;
    2) add_protocol "vmess" "#vmess" "vmess" "vmess-grpc" ;;
    3) add_protocol "trojan" "#trojan" "trojan-ws" "trojan-grpc" ;;
    4) add_protocol "shadowsocks" "#ss" "ss-ws" "ss-grpc" ;;
    5) add_protocol "socks" "#socks" "socks-ws" "socks-grpc" ;;
    6) delete_user ;;
    7) list_users ;;
    8) menu 2>/dev/null || echo "Main menu not found" ;;
    *) echo -e "${RED}Invalid option${NC}" ;;
esac
read -n 1 -s -r -p "Press any key to continue..."
