#!/bin/bash
# ============================================================
# MARCSCRIPT ALL-IN-ONE VPN SETUP - FIXED EDITION
# IP-Only | Self-Signed SSL | JSON User Output
# ============================================================
set -e
GITHUB_RAW="https://raw.githubusercontent.com/Jhon-mark23/blueblue/main"
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
{"installation":{"id":"$INSTALL_ID","timestamp":"$(date -Iseconds)","status":"running","vps_ip":"$(curl -s ifconfig.me || echo unknown)"},"errors":[],"warnings":[]}
EOF
}

update_json() {
    command -v jq &>/dev/null && jq ".$1 = \"$2\"" "$JSON_FILE" > "$JSON_FILE.tmp" && mv "$JSON_FILE.tmp" "$JSON_FILE" || true
}

add_error_json() {
    command -v jq &>/dev/null && jq ".errors += [{\"time\":\"$(date -Iseconds)\",\"message\":\"$1\"}]" "$JSON_FILE" > "$JSON_FILE.tmp" && mv "$JSON_FILE.tmp" "$JSON_FILE" || true
}

safety_check() {
    [ "$EUID" -ne 0 ] && { log_error "Run as root!"; exit 1; }
    
    read -p "Proceed with installation? (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_error "Aborted."; exit 1; }
    
    mkdir -p "$BACKUP_DIR"
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup" 2>/dev/null || true
    cp /etc/stunnel/stunnel.conf "$BACKUP_DIR/stunnel.conf.backup" 2>/dev/null || true
    cp /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf.backup" 2>/dev/null || true
    cp /etc/squid/squid.conf "$BACKUP_DIR/squid.conf.backup" 2>/dev/null || true
    iptables-save > "$BACKUP_DIR/iptables.backup" 2>/dev/null || true
    
    cat > "$BACKUP_DIR/rollback.sh" <<'RB'
#!/bin/bash
BD="$(dirname "$0")"
[ -f "$BD/sshd_config.backup" ] && cp "$BD/sshd_config.backup" /etc/ssh/sshd_config && systemctl restart ssh
[ -f "$BD/stunnel.conf.backup" ] && cp "$BD/stunnel.conf.backup" /etc/stunnel/stunnel.conf && systemctl restart stunnel4 2>/dev/null
[ -f "$BD/nginx.conf.backup" ] && cp "$BD/nginx.conf.backup" /etc/nginx/nginx.conf && systemctl restart nginx 2>/dev/null
[ -f "$BD/squid.conf.backup" ] && cp "$BD/squid.conf.backup" /etc/squid/squid.conf && systemctl restart squid 2>/dev/null
[ -f "$BD/iptables.backup" ] && iptables-restore < "$BD/iptables.backup"
echo "Rollback complete"
RB
    chmod +x "$BACKUP_DIR/rollback.sh"
}

rollback() {
    log_error "Failed: $1"
    bash "$BACKUP_DIR/rollback.sh" 2>/dev/null
    update_json installation.status "failed"
    add_error_json "Installation failed at: $1"
    exit 1
}

install_packages() {
    log_info "Installing packages..."
    apt update -y >> "$LOG_FILE" 2>&1 || true
    
    for pkg in openssh-server stunnel4 nginx curl wget lsof squid ufw openssl net-tools jq pwgen cron socat dnsutils lsb-release unzip; do
        if ! dpkg -l | grep -q "^ii  $pkg"; then
            apt install -y $pkg >> "$LOG_FILE" 2>&1 || rollback "pkg:$pkg"
        fi
    done
    
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >> "$LOG_FILE" 2>&1
        apt install -y nodejs >> "$LOG_FILE" 2>&1 || rollback "nodejs"
    fi
    
    log_ok "Packages installed"
}

configure_ssh() {
    log_info "Configuring SSH..."
    sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config
    sed -i '/^Port 80/d' /etc/ssh/sshd_config  # Remove port 80 to avoid conflict
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    sshd -t >> "$LOG_FILE" 2>&1 || rollback "ssh-config"
    systemctl restart ssh && systemctl enable ssh || rollback "ssh-restart"
    log_ok "SSH on port 22"
}

configure_stunnel() {
    log_info "Configuring Stunnel SSL..."
    openssl req -new -x509 -days 3650 -nodes \
        -subj "/CN=MarcScript" \
        -out /etc/stunnel/stunnel.pem \
        -keyout /etc/stunnel/stunnel.pem >> "$LOG_FILE" 2>&1 || rollback "stunnel-cert"
    
    cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
client = no
[ssh-ssl]
accept = 8443
connect = 127.0.0.1:22
cert = /etc/stunnel/stunnel.pem
TIMEOUTclose = 0
EOF
    
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
    systemctl restart stunnel4 && systemctl enable stunnel4 || rollback "stunnel-start"
    log_ok "Stunnel on port 8443 (SSH SSL)"
}

configure_websocket() {
    log_info "Configuring WebSocket proxy..."
    mkdir -p /opt/ws-proxy
    wget -q -O /opt/ws-proxy/ws-proxy.js "${GITHUB_RAW}/ws-proxy.js" || {
        # Fallback inline if GitHub fails
        cat > /opt/ws-proxy/ws-proxy.js <<'WSEOF'
#!/usr/bin/env node
const net = require('net');
const http = require('http');
const SSH_HOST = '127.0.0.1', SSH_PORT = 22, WS_PORT = 8080;
const server = http.createServer();
server.on('upgrade', (req, socket) => {
    const ssh = net.connect(SSH_PORT, SSH_HOST, () => {
        socket.write('HTTP/1.1 101 OK\r\n\r\n');
        ssh.pipe(socket);
        socket.pipe(ssh);
    });
    ssh.on('error', () => socket.destroy());
});
server.listen(WS_PORT, '0.0.0.0', () => console.log('WS on', WS_PORT));
WSEOF
    }
    chmod +x /opt/ws-proxy/ws-proxy.js
    
    cat > /etc/systemd/system/ws-proxy.service <<EOF
[Unit]
Description=SSH WebSocket Proxy
After=network.target
[Service]
ExecStart=/usr/bin/node /opt/ws-proxy/ws-proxy.js
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload && systemctl enable ws-proxy && systemctl start ws-proxy || rollback "ws-start"
    log_ok "WebSocket proxy on port 8080"
}

configure_squid() {
    log_info "Configuring Squid proxy..."
    cat > /etc/squid/squid.conf <<'SQEOF'
http_port 3128
http_port 8082
http_port 8888
acl all src 0.0.0.0/0
http_access allow all
cache_dir ufs /var/spool/squid 100 16 256
forwarded_for off
visible_hostname localhost
dns_nameservers 8.8.8.8 1.1.1.1
SQEOF
    
    mkdir -p /var/spool/squid
    chown -R proxy:proxy /var/spool/squid 2>/dev/null || true
    squid -z >> "$LOG_FILE" 2>&1 || true
    systemctl restart squid && systemctl enable squid || rollback "squid-start"
    log_ok "Squid on ports 3128, 8082, 8888"
}

configure_xray() {
    [ "$XRAY_ENABLED" != "true" ] && { update_json xray.status "skipped"; return 0; }
    
    log_info "Installing Xray Core..."
    
    # Get public IP
    domain=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
    [ -z "$domain" ] && rollback "Cannot detect IP"
    echo "$domain" > /etc/xray/domain
    update_json xray.domain "$domain"
    
    # Create directories with CORRECT permissions
    rm -rf /var/log/xray /home/vps/public_html
    mkdir -p /var/log/xray
    mkdir -p /home/vps/public_html
    mkdir -p /etc/xray
    mkdir -p /usr/local/etc/xray
    
    # Set ownership BEFORE creating files
    chown -R www-data:www-data /var/log/xray
    chown -R www-data:www-data /etc/xray
    chmod 755 /var/log/xray
    chmod 755 /etc/xray
    
    # Create log files with correct ownership
    touch /var/log/xray/access.log /var/log/xray/error.log
    chown www-data:www-data /var/log/xray/*.log
    chmod 644 /var/log/xray/*.log
    
    # Download Nginx configs
    wget -q -O /etc/nginx/nginx.conf "${GITHUB_RAW}/nginx.conf" 2>/dev/null || {
        cat > /etc/nginx/nginx.conf <<'NGXEOF'
user www-data;
worker_processes 1;
pid /var/run/nginx.pid;
events { multi_accept on; worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    server_tokens off;
    include /etc/nginx/conf.d/*.conf;
}
NGXEOF
    }
    
    wget -q -O /etc/nginx/conf.d/vps.conf "${GITHUB_RAW}/vps.conf" 2>/dev/null || {
        cat > /etc/nginx/conf.d/vps.conf <<'VPSEOF'
server {
    listen 81;
    server_name 127.0.0.1 localhost;
    root /home/vps/public_html;
    location / { index index.html index.htm; }
}
VPSEOF
    }
    
    # Generate self-signed SSL certificate
    log_info "Generating self-signed SSL certificate for $domain"
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/CN=${domain}" \
        -keyout /etc/xray/xray.key \
        -out /etc/xray/xray.crt >> "$LOG_FILE" 2>&1
    chmod 644 /etc/xray/xray.crt /etc/xray/xray.key
    
    # Install Xray binary
    latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases | grep tag_name | head -1 | sed -E 's/.*"v(.*)".*/\1/')
    [ -z "$latest" ] && latest="1.8.23"
    
    cd $(mktemp -d)
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/v${latest}/xray-linux-64.zip" -o xray.zip || rollback "xray-download"
    unzip -q xray.zip && rm xray.zip
    mv xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    
    # Generate random internal ports & UUID
    vless_ws=$((RANDOM+10000))
    vmess_ws=$((RANDOM+10000))
    trojan_ws=$((RANDOM+10000))
    ss_ws=$((RANDOM+10000))
    vless_g=$((RANDOM+10000))
    vmess_g=$((RANDOM+10000))
    trojan_g=$((RANDOM+10000))
    ss_g=$((RANDOM+10000))
    uuid=$(cat /proc/sys/kernel/random/uuid)
    update_json xray.uuid "$uuid"
    
    # Nginx reverse proxy config
    cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    listen 443 ssl http2 reuseport;
    listen [::]:443 http2 reuseport;
    server_name ${domain};
    ssl_certificate /etc/xray/xray.crt;
    ssl_certificate_key /etc/xray/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    root /home/vps/public_html;

    location / {
        proxy_pass http://127.0.0.1:700;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location = /vless {
        proxy_pass http://127.0.0.1:${vless_ws};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location = /vmess {
        proxy_pass http://127.0.0.1:${vmess_ws};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location = /trojan-ws {
        proxy_pass http://127.0.0.1:${trojan_ws};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location = /ss-ws {
        proxy_pass http://127.0.0.1:${ss_ws};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location ^~ /vless-grpc {
        grpc_pass grpc://127.0.0.1:${vless_g};
        grpc_set_header Host \$host;
    }
    location ^~ /vmess-grpc {
        grpc_pass grpc://127.0.0.1:${vmess_g};
        grpc_set_header Host \$host;
    }
    location ^~ /trojan-grpc {
        grpc_pass grpc://127.0.0.1:${trojan_g};
        grpc_set_header Host \$host;
    }
    location ^~ /ss-grpc {
        grpc_pass grpc://127.0.0.1:${ss_g};
        grpc_set_header Host \$host;
    }
}
EOF
    
    # Xray config (valid JSON, no comments, empty users)
    cat > /etc/xray/config.json <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${vless_ws},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vless"}
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${vmess_ws},
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess"}
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${trojan_ws},
      "protocol": "trojan",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/trojan-ws"}
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${ss_ws},
      "protocol": "shadowsocks",
      "settings": {
        "clients": [],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/ss-ws"}
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${vless_g},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": []
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {"serviceName": "vless-grpc"}
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${vmess_g},
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {"serviceName": "vmess-grpc"}
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${trojan_g},
      "protocol": "trojan",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {"serviceName": "trojan-grpc"}
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${ss_g},
      "protocol": "shadowsocks",
      "settings": {
        "clients": [],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {"serviceName": "ss-grpc"}
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "127.0.0.0/8"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
    
    # Systemd service for Xray
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=www-data
Group=www-data
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    
    # Validate and start
    nginx -t >> "$LOG_FILE" 2>&1 || {
        log_error "Nginx config invalid"
        nginx -t 2>&1 | tail -5
        rollback "nginx-config"
    }
    
    systemctl daemon-reload
    systemctl enable xray nginx
    systemctl restart nginx
    sleep 2
    
    # Start Xray with verification
    if ! systemctl start xray; then
        log_error "Xray failed to start. Checking logs..."
        journalctl -u xray --no-pager -n 20 >> "$LOG_FILE"
        # Try fix permissions again
        chown -R www-data:www-data /var/log/xray /etc/xray
        systemctl start xray || rollback "xray-start"
    fi
    
    sleep 3
    systemctl is-active --quiet xray || rollback "xray-not-active"
    systemctl is-active --quiet nginx || rollback "nginx-not-active"
    
    chown -R www-data:www-data /home/vps/public_html
    update_json xray.status "running"
    log_ok "Xray & Nginx running on $domain:443"
}

configure_api() {
    log_info "Configuring API..."
    mkdir -p /opt/marcscript-api
    
    wget -q -O /opt/marcscript-api/api.js "${GITHUB_RAW}/api.js" 2>/dev/null || {
        cat > /opt/marcscript-api/api.js <<'APIEOF'
#!/usr/bin/env node
const http = require('http');
const server = http.createServer((req, res) => {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({status:"running",api:3021}));
});
server.listen(3021, '127.0.0.1');
APIEOF
    }
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
    PORTS="22 80 81 443 8080 8082 8443 3128 8888"
    
    if command -v ufw &>/dev/null; then
        ufw --force reset >> "$LOG_FILE" 2>&1
        for p in $PORTS; do ufw allow ${p}/tcp >> "$LOG_FILE" 2>&1; done
        ufw --force enable >> "$LOG_FILE" 2>&1
        log_ok "UFW configured"
    else
        for p in $PORTS; do iptables -A INPUT -p tcp --dport $p -j ACCEPT; done
        iptables-save > /etc/iptables.rules
        log_ok "iptables configured"
    fi
}

setup_scripts() {
    # Download add-xray and menu
    wget -q -O /usr/local/bin/add-xray "${GITHUB_RAW}/add-xray.sh" 2>/dev/null || log_warn "add-xray download failed"
    wget -q -O /usr/local/bin/menu "${GITHUB_RAW}/menu.sh" 2>/dev/null || log_warn "menu download failed"
    chmod +x /usr/local/bin/add-xray /usr/local/bin/menu 2>/dev/null
    
    # SSH user creator
    cat > /usr/local/bin/create <<'EOF'
#!/bin/bash
read -p "Username: " u; read -p "Password: " p; read -p "Days: " d
useradd -m -s /bin/bash "$u" && echo "$u:$p" | chpasswd && chage -E $(date -d "$d days" +%Y-%m-%d) "$u"
echo "User $u created, expires in $d days"
EOF
    chmod +x /usr/local/bin/create
    
    # Status
    cat > /usr/local/bin/vpn-status <<'EOF'
#!/bin/bash
echo "================================"
echo "  MARCSCRIPT VPN STATUS"
echo "================================"
echo "SSH     : $(systemctl is-active ssh)"
echo "WS      : $(systemctl is-active ws-proxy)"
echo "Stunnel : $(systemctl is-active stunnel4)"
echo "Xray    : $(systemctl is-active xray 2>/dev/null || echo inactive)"
echo "Nginx   : $(systemctl is-active nginx 2>/dev/null || echo inactive)"
echo "Squid   : $(systemctl is-active squid 2>/dev/null || echo inactive)"
echo "API     : $(systemctl is-active marcscript-api 2>/dev/null || echo inactive)"
echo "IP      : $(curl -s ifconfig.me)"
echo "================================"
EOF
    chmod +x /usr/local/bin/vpn-status
    
    log_ok "Management scripts installed"
}

# Main
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
    
    IP=$(curl -s ifconfig.me)
    clear
    echo "============================================"
    echo "   MARCSCRIPT VPN INSTALLATION COMPLETE!"
    echo "============================================"
    echo " IP        : $IP"
    echo " SSH       : 22"
    echo " SSH SSL   : 8443 (Stunnel)"
    echo " SSH WS    : 8080"
    echo " Squid     : 3128, 8082, 8888"
    echo " Xray TLS  : 443"
    echo "   VLESS   : /vless, vless-grpc"
    echo "   VMess   : /vmess, vmess-grpc"
    echo "   Trojan  : /trojan-ws, trojan-grpc"
    echo "   SS      : /ss-ws, ss-grpc"
    echo " API       : localhost:3021"
    echo ""
    echo " Commands: menu | add-xray | create | vpn-status"
    echo " Backup: $BACKUP_DIR"
    echo "============================================"
}

trap 'rollback "unexpected"' ERR
main "$@"
