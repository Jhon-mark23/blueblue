#!/bin/bash
# ============================================================
# MARCSCRIPT ALL-IN-ONE VPN SETUP - REDUCED
# Repository: https://github.com/YOUR_USERNAME/YOUR_REPO
# ============================================================
set -e
GITHUB_RAW="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main"
BACKUP_DIR="/root/ssh-vpn-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/marcscript-vpn-install.log"
JSON_FILE="/etc/marcscript-vpn-config.json"
INSTALL_ID=$(date +%Y%m%d_%H%M%S)
API_PORT=3021
XRAY_ENABLED=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1";  echo "[$(date)] [INFO] $1" >> "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; echo "[$(date)] [WARN] $1" >> "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1";    echo "[$(date)] [ERROR] $1" >> "$LOG_FILE"; }
log_ok()    { echo -e "${BLUE}[OK]${NC} $1";      echo "[$(date)] [OK] $1" >> "$LOG_FILE"; }

init_json() {
    cat > "$JSON_FILE" <<EOF
{"installation":{"id":"$INSTALL_ID","timestamp":"$(date -Iseconds)","status":"running"},"errors":[],"warnings":[]}
EOF
}
update_json() { command -v jq &>/dev/null && jq ".$1 = \"$2\"" "$JSON_FILE" > "$JSON_FILE.tmp" && mv "$JSON_FILE.tmp" "$JSON_FILE" || true; }

safety_check() {
    [ "$EUID" -ne 0 ] && { log_error "Run as root!"; exit 1; }
    mkdir -p "$BACKUP_DIR"
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup" 2>/dev/null || true
    cp /etc/stunnel/stunnel.conf "$BACKUP_DIR/stunnel.conf.backup" 2>/dev/null || true
    cp /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf.backup" 2>/dev/null || true
    iptables-save > "$BACKUP_DIR/iptables.backup" 2>/dev/null || true
    cat > "$BACKUP_DIR/rollback.sh" <<'RB'
#!/bin/bash
BD="$(dirname "$0")"
[ -f "$BD/sshd_config.backup" ] && cp "$BD/sshd_config.backup" /etc/ssh/sshd_config && systemctl restart ssh
[ -f "$BD/stunnel.conf.backup" ] && cp "$BD/stunnel.conf.backup" /etc/stunnel/stunnel.conf && systemctl restart stunnel4 2>/dev/null
[ -f "$BD/nginx.conf.backup" ] && cp "$BD/nginx.conf.backup" /etc/nginx/nginx.conf && systemctl restart nginx 2>/dev/null
[ -f "$BD/iptables.backup" ] && iptables-restore < "$BD/iptables.backup"
echo "Rollback complete"
RB
    chmod +x "$BACKUP_DIR/rollback.sh"
}

rollback() { log_error "Failed: $1"; bash "$BACKUP_DIR/rollback.sh"; exit 1; }

install_packages() {
    apt update -y >> "$LOG_FILE" 2>&1
    for pkg in openssh-server stunnel4 nginx curl wget lsof squid ufw openssl net-tools jq pwgen cron socat dnsutils lsb-release nodejs; do
        dpkg -l | grep -q "^ii  $pkg" || apt install -y $pkg >> "$LOG_FILE" 2>&1 || rollback "pkg:$pkg"
    done
    if ! command -v node; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >> "$LOG_FILE" 2>&1
        apt install -y nodejs >> "$LOG_FILE" 2>&1 || rollback "nodejs"
    fi
}

configure_ssh() {
    sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config
    grep -q "^Port 80" /etc/ssh/sshd_config || echo "Port 80" >> /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    systemctl restart ssh && systemctl enable ssh || rollback "ssh"
    log_ok "SSH on 22,80"
}

configure_stunnel() {
    openssl req -new -x509 -days 3650 -nodes -subj "/CN=MarcScript" -out /etc/stunnel/stunnel.pem -keyout /etc/stunnel/stunnel.pem >> "$LOG_FILE" 2>&1
    cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
[ssh-ssl]
accept = 8443
connect = 127.0.0.1:22
cert = /etc/stunnel/stunnel.pem
EOF
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
    systemctl restart stunnel4 && systemctl enable stunnel4 || rollback "stunnel"
    log_ok "Stunnel on 8443 (SSH SSL)"
}

configure_websocket() {
    mkdir -p /opt/ws-proxy
    wget -q -O /opt/ws-proxy/ws-proxy.js "${GITHUB_RAW}/ws-proxy.js" || rollback "ws-dl"
    chmod +x /opt/ws-proxy/ws-proxy.js
    cat > /etc/systemd/system/ws-proxy.service <<EOF
[Unit]
Description=SSH WS Proxy
After=network.target
[Service]
ExecStart=/usr/bin/node /opt/ws-proxy/ws-proxy.js
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable ws-proxy && systemctl start ws-proxy || rollback "ws"
    log_ok "WebSocket proxy on 8080"
}

configure_squid() {
    cat > /etc/squid/squid.conf <<EOF
http_port 3128
http_port 8082
http_port 8888
acl all src 0.0.0.0/0
http_access allow all
cache_dir ufs /var/spool/squid 100 16 256
forwarded_for off
visible_hostname localhost
EOF
    mkdir -p /var/spool/squid; chown -R proxy:proxy /var/spool/squid 2>/dev/null || true
    squid -z >> "$LOG_FILE" 2>&1 || true
    systemctl restart squid && systemctl enable squid || rollback "squid"
    log_ok "Squid on 3128,8082,8888"
}

configure_xray() {
    [ "$XRAY_ENABLED" != "true" ] && return
    domain=$(cat /etc/xray/domain 2>/dev/null || curl -s ifconfig.me)
    mkdir -p /var/log/xray /home/vps/public_html /etc/xray /usr/local/etc/xray
    chown www-data:www-data /var/log/xray /etc/xray
    wget -q -O /etc/nginx/nginx.conf "${GITHUB_RAW}/nginx.conf"
    wget -q -O /etc/nginx/conf.d/vps.conf "${GITHUB_RAW}/vps.conf"

    # SSL
    curl -s https://get.acme.sh | sh >> "$LOG_FILE" 2>&1
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >> "$LOG_FILE" 2>&1
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256 >> "$LOG_FILE" 2>&1 || {
        log_warn "Self-signed cert"
        openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 -subj "/CN=$domain" -keyout /etc/xray/xray.key -out /etc/xray/xray.crt >> "$LOG_FILE" 2>&1
    }
    [ -f ~/.acme.sh/${domain}_ecc/${domain}.cer ] && ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc --fullchain-file /etc/xray/xray.crt --key-file /etc/xray/xray.key
    chmod 644 /etc/xray/xray.{crt,key}

    # Xray binary
    latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases | grep tag_name | head -1 | sed -E 's/.*"v(.*)".*/\1/')
    [ -z "$latest" ] && latest="1.8.23"
    cd $(mktemp -d)
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/v${latest}/xray-linux-64.zip" -o xray.zip
    unzip -q xray.zip && mv xray /usr/local/bin/xray && chmod +x /usr/local/bin/xray

    # Random ports + UUID
    vless_ws=$((RANDOM+10000)); vmess_ws=$((RANDOM+10000)); trojan_ws=$((RANDOM+10000)); ss_ws=$((RANDOM+10000))
    vless_g=$((RANDOM+10000)); vmess_g=$((RANDOM+10000)); trojan_g=$((RANDOM+10000)); ss_g=$((RANDOM+10000))
    uuid=$(cat /proc/sys/kernel/random/uuid)

    # Nginx xray.conf
    cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 80; listen [::]:80;
    listen 443 ssl http2 reuseport; listen [::]:443 http2 reuseport;
    server_name $domain;
    ssl_certificate /etc/xray/xray.crt;
    ssl_certificate_key /etc/xray/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /home/vps/public_html;
    location / { proxy_pass http://127.0.0.1:700; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$http_host; }
    location = /vless { proxy_pass http://127.0.0.1:${vless_ws}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$http_host; }
    location = /vmess { proxy_pass http://127.0.0.1:${vmess_ws}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$http_host; }
    location = /trojan-ws { proxy_pass http://127.0.0.1:${trojan_ws}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$http_host; }
    location = /ss-ws { proxy_pass http://127.0.0.1:${ss_ws}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$http_host; }
    location ^~ /vless-grpc { grpc_pass grpc://127.0.0.1:${vless_g}; }
    location ^~ /vmess-grpc { grpc_pass grpc://127.0.0.1:${vmess_g}; }
    location ^~ /trojan-grpc { grpc_pass grpc://127.0.0.1:${trojan_g}; }
    location ^~ /ss-grpc { grpc_pass grpc://127.0.0.1:${ss_g}; }
}
EOF

    # Xray config.json (empty clients, users added later)
    cat > /etc/xray/config.json <<EOF
{"log":{"access":"/var/log/xray/access.log","error":"/var/log/xray/error.log","loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":${vless_ws},"protocol":"vless","settings":{"decryption":"none","clients":[]},"streamSettings":{"network":"ws","wsSettings":{"path":"/vless"}}},{"listen":"127.0.0.1","port":${vmess_ws},"protocol":"vmess","settings":{"clients":[]},"streamSettings":{"network":"ws","wsSettings":{"path":"/vmess"}}},{"listen":"127.0.0.1","port":${trojan_ws},"protocol":"trojan","settings":{"clients":[]},"streamSettings":{"network":"ws","wsSettings":{"path":"/trojan-ws"}}},{"listen":"127.0.0.1","port":${ss_ws},"protocol":"shadowsocks","settings":{"clients":[],"network":"tcp,udp"},"streamSettings":{"network":"ws","wsSettings":{"path":"/ss-ws"}}},{"listen":"127.0.0.1","port":${vless_g},"protocol":"vless","settings":{"decryption":"none","clients":[]},"streamSettings":{"network":"grpc","grpcSettings":{"serviceName":"vless-grpc"}}},{"listen":"127.0.0.1","port":${vmess_g},"protocol":"vmess","settings":{"clients":[]},"streamSettings":{"network":"grpc","grpcSettings":{"serviceName":"vmess-grpc"}}},{"listen":"127.0.0.1","port":${trojan_g},"protocol":"trojan","settings":{"clients":[]},"streamSettings":{"network":"grpc","grpcSettings":{"serviceName":"trojan-grpc"}}},{"listen":"127.0.0.1","port":${ss_g},"protocol":"shadowsocks","settings":{"clients":[],"network":"tcp,udp"},"streamSettings":{"network":"grpc","grpcSettings":{"serviceName":"ss-grpc"}}}],"outbounds":[{"protocol":"freedom","settings":{}},{"protocol":"blackhole","settings":{},"tag":"blocked"}],"routing":{"rules":[{"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"],"outboundTag":"blocked"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"}]}}
EOF

    # Xray service
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
User=www-data
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
LimitNPROC=10000
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF

    # SSL renewal cron
    echo '#!/bin/bash
systemctl stop nginx
"/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" &> /root/renew_ssl.log
systemctl start nginx' > /usr/local/bin/ssl_renew.sh
    chmod +x /usr/local/bin/ssl_renew.sh
    (crontab -l 2>/dev/null | grep -v ssl_renew; echo "15 03 */3 * * /usr/local/bin/ssl_renew.sh") | crontab -

    nginx -t >> "$LOG_FILE" 2>&1 || rollback "nginx-conf"
    systemctl daemon-reload
    systemctl enable xray nginx
    systemctl start xray nginx
    log_ok "Xray & Nginx running (443)"
}

configure_api() {
    mkdir -p /opt/marcscript-api
    wget -q -O /opt/marcscript-api/api.js "${GITHUB_RAW}/api.js"
    chmod +x /opt/marcscript-api/api.js
    cat > /etc/systemd/system/marcscript-api.service <<EOF
[Unit]
Description=MarcScript API
After=network.target
[Service]
ExecStart=/usr/bin/node /opt/marcscript-api/api.js
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable marcscript-api && systemctl start marcscript-api
    log_ok "API on localhost:3021"
}

configure_firewall() {
    PORTS="22 80 81 8080 8082 8443 3128 8888"
    [ "$XRAY_ENABLED" = "true" ] && PORTS="$PORTS 443"
    if command -v ufw &>/dev/null; then
        ufw --force reset >> "$LOG_FILE" 2>&1
        for p in $PORTS; do ufw allow ${p}/tcp >> "$LOG_FILE" 2>&1; done
        ufw --force enable >> "$LOG_FILE" 2>&1
    else
        for p in $PORTS; do iptables -A INPUT -p tcp --dport $p -j ACCEPT; done
        iptables-save > /etc/iptables.rules
    fi
    log_ok "Firewall configured"
}

setup_scripts() {
    wget -q -O /usr/local/bin/add-xray "${GITHUB_RAW}/add-xray.sh" && chmod +x /usr/local/bin/add-xray
    wget -q -O /usr/local/bin/menu "${GITHUB_RAW}/menu.sh" && chmod +x /usr/local/bin/menu

    # Simple SSH user creator
    cat > /usr/local/bin/create <<'EOF'
#!/bin/bash
read -p "Username: " u; read -p "Password: " p; read -p "Expired (days): " d
useradd -m -s /bin/bash "$u" && echo "$u:$p" | chpasswd && chage -E $(date -d "$d days" +%Y-%m-%d) "$u"
echo "User $u created, expires in $d days"
EOF
    chmod +x /usr/local/bin/create

    # Status command
    cat > /usr/local/bin/vpn-status <<'EOF'
#!/bin/bash
echo "SSH: $(systemctl is-active ssh) | WS: $(systemctl is-active ws-proxy) | Stunnel: $(systemctl is-active stunnel4)"
echo "Xray: $(systemctl is-active xray 2>/dev/null || echo inactive) | Nginx: $(systemctl is-active nginx 2>/dev/null || echo inactive)"
echo "Squid: $(systemctl is-active squid 2>/dev/null || echo inactive) | API: $(systemctl is-active marcscript-api 2>/dev/null || echo inactive)"
echo "IP: $(curl -s ifconfig.me)"
EOF
    chmod +x /usr/local/bin/vpn-status
    log_ok "Management scripts installed"
}

main() {
    init_json
    safety_check
    install_packages
    configure_ssh
    configure_stunnel
    configure_websocket
    configure_squid
    configure_xray
    configure_api
    configure_firewall
    setup_scripts
    update_json installation.status "completed"

    clear
    echo "============================================"
    echo "   MARCSCRIPT VPN INSTALLATION COMPLETE"
    echo "============================================"
    echo " SSH       : 22, 80"
    echo " SSH SSL   : 8443 (Stunnel)"
    echo " SSH WS    : 8080 (ws-proxy)"
    echo " Squid     : 3128, 8082, 8888"
    [ "$XRAY_ENABLED" = "true" ] && echo " Xray TLS  : 443 (VLESS/VMess/Trojan/SS/Socks)"
    echo ""
    echo " Commands:  menu | add-xray | create | vpn-status"
    echo " Backup:    $BACKUP_DIR"
    echo "============================================"
}

trap 'rollback "unexpected"' ERR
main "$@"
