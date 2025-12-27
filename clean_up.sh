#!/bin/bash

### CLEAN UP SCRIPT ###

echo "Stopping and removing WireGuard containers..."
if [ -d "/opt/wireguard" ]; then
    cd /opt/wireguard
    docker compose down
    cd /
    sudo rm -rf /opt/wireguard
fi

echo "Cleaning up Nginx configurations..."
DOMAIN_NAME="YOUR_DOMAIN"

sudo rm -f /etc/nginx/sites-enabled/wg-easy
sudo rm -f /etc/nginx/sites-available/wg-easy
sudo systemctl restart nginx

echo "Removing SSL certificates..."
sudo certbot delete --cert-name $DOMAIN_NAME

echo "Uninstalling packages..."
# Optional, remove packages from uninstall process if you use them
sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
docker-compose-plugin nginx python3-certbot-nginx docker.io

sudo apt autoremove -y
sudo apt autoclean

echo "Disabling IP forwarding..."
sudo sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
sudo sysctl -w net.ipv4.ip_forward=0

echo "Final Docker cleanup (volumes and networks)..."
sudo rm -rf /var/lib/docker
sudo rm -rf /etc/docker
sudo rm -rf /etc/apt/sources.list.d/docker.list
sudo rm -f /etc/apt/keyrings/docker.gpg

echo "------------------------------------------"
echo "System is clean! All components removed."
echo "------------------------------------------"