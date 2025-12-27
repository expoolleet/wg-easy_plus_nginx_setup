#!/bin/bash

# ==============================================================================
# ADGUARD HOME + WIREGUARD-EASY DOCKER + NGINX AUTOMATION SCRIPT
# ==============================================================================

### If you using free DNS services, you need to assing public IP to the new created domain, like that:
### duckdns: curl "https://www.duckdns.org/update?domains=NAME&token=TOKEN&ip="
### dedyn.io: curl -4 "https://update.dedyn.io/update?username=NAME&password=TOKEN"

# Root check
if [[ $EUID -ne 0 ]]; then
   echo "Root (sudo) privileges are required to run this script" 
   exit 1
fi

# --- 0. Environment Variables ---
EMAIL="your-email@gmail.com"
DOMAIN_NAME="YOUR_DOMAIN_NAME"
ADMIN_PASS="YOUR_PASSWORD"
VPN_IP="10.8.0.0/24"          # VPN Network Subnet
VPN_GATEWAY="10.8.0.1"        # DNS address for clients
PUBLIC_IP=$(curl -s -4 ifconfig.me)

# --- 1. Conflict Resolution (systemd-resolved) ---
echo "Stopping and disabling systemd-resolved to free port 53..."
systemctl stop systemd-resolved
systemctl disable systemd-resolved

# Reset resolv.conf to prevent DNS loss on the host
rm /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# --- 2. AdGuard Home Installation ---
echo "Installing AdGuard Home..."
cd /opt
wget https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar -xzf AdGuardHome_linux_amd64.tar.gz
rm AdGuardHome_linux_amd64.tar.gz
cd AdGuardHome
./AdGuardHome -s install

# --- 3. Firewall Configuration (UFW) ---
echo "Configuring UFW rules..."
sudo apt update && sudo apt install ufw -y
ufw allow 22/tcp 
ufw allow 51820/udp
ufw allow 80/tcp
ufw allow 443/tcp
# Allow DNS and Admin Panel only from VPN network for security
ufw allow from $VPN_IP to any port 53
ufw allow from $VPN_IP to any port 3000
ufw allow from $VPN_IP to any port 3001
ufw enable

# --- 4. AdGuard Initial Configuration ---
echo "Setting AdGuard to listen on all interfaces..."
./AdGuardHome -s start
sleep 2
CONFIG="/opt/AdGuardHome/AdGuardHome.yaml"
if [ -f "$CONFIG" ]; then
    sed -i 's/bind_host: .*/bind_host: 0.0.0.0/g' "$CONFIG"
    sed -i 's/bind_hosts:.*/bind_hosts:\n  - 0.0.0.0/g' "$CONFIG"
fi
./AdGuardHome -s restart

# --- 5. Docker & Dependencies Installation ---
echo "Installing Docker and Nginx..."
sudo apt update
sudo apt install -y ca-certificates curl gnupg nginx python3-certbot-nginx
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable IP Forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# --- 6. WireGuard-Easy Deployment ---
echo "Setting up wg-easy..."
ADMIN_PASS_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw $ADMIN_PASS | cut -d"'" -f2 | sed 's/\$/$$/g')

mkdir -p /opt/wireguard
cd /opt/wireguard

cat << EOF > docker-compose.yml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    network_mode: "host"
    container_name: wg-easy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      - WG_HOST=$PUBLIC_IP
      - PASSWORD_HASH=$ADMIN_PASS_HASH
      - WG_PORT=51820
      - WG_DEFAULT_DNS=$VPN_GATEWAY
      - WG_MTU=1280
      - WG_ALLOWED_IPS=0.0.0.0/0
      - WG_DEFAULT_ADDRESS=${VPN_IP%/*}
    volumes:
      - ./config:/etc/wireguard
EOF

docker compose up -d

# --- 7. Nginx Reverse Proxy Setup ---
echo "Configuring Nginx Reverse Proxy..."
cat << EOF > /etc/nginx/sites-available/wg-easy

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    server_name _;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;

    return 444;
}

server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://127.0.0.1:51821;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/wg-easy /etc/nginx/sites-enabled/wg-easy
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# --- 8. SSL via Certbot ---
echo "Obtaining SSL Certificate..."
sudo apt install snapd -y
sudo snap install core; sudo snap refresh core
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
certbot --nginx -d $DOMAIN_NAME --agree-tos -m $EMAIL --no-eff-email --redirect

echo "--------------------------------------------------------"
echo "INSTALLATION COMPLETE"
echo "VPN Web UI: https://$DOMAIN_NAME"
echo "AdGuard Admin: http://$PUBLIC_IP:3000 (Use VPN to access)"
echo "--------------------------------------------------------"

