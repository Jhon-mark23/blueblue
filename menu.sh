#!/bin/bash
clear
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[44;1;39m            MARCSCRIPT VPN MAIN MENU               \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e " SSH WS/SSL : $(systemctl is-active ws-proxy) / $(systemctl is-active stunnel4)"
echo -e " Xray Core  : $(systemctl is-active xray 2>/dev/null || echo inactive)"
echo -e " Nginx      : $(systemctl is-active nginx 2>/dev/null || echo inactive)"
echo -e " Squid      : $(systemctl is-active squid 2>/dev/null || echo inactive)"
echo -e " API        : $(systemctl is-active marcscript-api 2>/dev/null || echo inactive)"
echo -e " IP         : $(curl -s ifconfig.me)"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e " 1. Add SSH User"
echo -e " 2. Add Xray User (VLESS/VMess/Trojan/SS/Socks)"
echo -e " 3. Delete Xray User"
echo -e " 4. List Xray Users"
echo -e " 5. Service Status"
echo -e " 6. Restart All Services"
echo -e " 7. Reboot VPS"
echo -e " 0. Exit"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
read -p "Select : " choice

case $choice in
    1) /usr/local/bin/create ;;
    2) /usr/local/bin/add-xray ;;
    3) echo "Use add-xray -> Delete" ;; # can be modified
    4) grep -o '"email": "[^"]*"' /etc/xray/config.json | cut -d'"' -f4 ;;
    5) systemctl status ws-proxy stunnel4 xray nginx squid --no-pager ;;
    6) systemctl restart ws-proxy stunnel4 xray nginx squid ;;
    7) reboot ;;
    0) exit ;;
    *) echo "Invalid" ;;
esac
