#!/bin/bash

# WIREGUARD-EASY DOCKER IMAGE WITH NGINX SERVER INSTALLATION

# 1. Docker installation
# 1.1. Set up Docker's apt repository.
# 1.1.1. Adding docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 1.1.2. Adding the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update

# 1.2. Installing main components
apt update && apt install -y curl docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nginx python3-certbot-nginx

# 1.3. Enablind ip forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 2. Adding env variables
EMAIL="your-email@gmail.com"
PUBLIC_IP=$(curl -s -4 ifconfig.me)
DOMAIN_NAME="YOUR_DOMAIN_NAME"
ADMIN_PASS="YOUR_PASSWORD"
ADMIN_PASS_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw $ADMIN_PASS | cut -d"'" -f2 | sed 's/\$/$$/g')

### If you using free DNS services, you need to assing public IP to the new created domain, like that:
### duckdns: curl "https://www.duckdns.org/update?domains=NAME&token=TOKEN&ip="
### dedyn.io: curl -4 "https://update.dedyn.io/update?username=NAME&password=TOKEN"

# 3. Creating Wireguard directory
mkdir -p /opt/wireguard
cd /opt/wireguard

# 4. Creating docker compose config file
cat << EOF > docker-compose.yml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
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
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_MTU=1420
      - WG_ALLOWED_IPS=0.0.0.0/0
    ports:
      - "51820:51820/udp"
      - "127.0.0.1:51821:51821/tcp"
    volumes:
      - ./config:/etc/wireguard
EOF

# 5. Starting docker compose
docker compose up -d

# 6. Nginx configuration
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

        # Correct WebSockets configuration
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";

        # Transfer of real headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 6.1. Activating page (creating symlink)
ln -sf /etc/nginx/sites-available/wg-easy /etc/nginx/sites-enabled/wg-easy

# 6.2. Removing default page (optional)
rm -f /etc/nginx/sites-enabled/default

# 6.3. Restarting Nginx
nginx -t && systemctl restart nginx

# 7. Setting up SSL certificate for our domain
# 7.1. Installing snap packaging format will allow us to intall a newer version of certbot
sudo apt install snapd -y
sudo snap install core; sudo snap refresh core
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot

# 7.2. Setting up nginx with certbot
certbot --nginx -d $DOMAIN_NAME --agree-tos -m $EMAIL --no-eff-email --redirect

echo "VPN Ready! https://$DOMAIN_NAME"



