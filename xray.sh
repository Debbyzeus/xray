#!/bin/bash
set -e

DOMAIN="a.debb1.me"      # Change this
EMAIL="debbyzeus@gmail.com"
UUID=$(xray uuid)
BACKEND_PORT="10086"
WS_PATH="/ssh"

echo "[1/5] Installing nginx, certbot, xray..."
apt update && apt install -y nginx certbot
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install.sh)" @ install

echo "[2/5] Getting SSL cert..."
certbot certonly --nginx -d $DOMAIN --email $EMAIL --agree-tos -n

echo "[3/5] Writing Xray config for TCP forwarding..."
tee /usr/local/etc/xray/config.json > /dev/null <<EOF
{
  "inbounds": [
    {
      "port": $BACKEND_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["ssh-in"],
        "outboundTag": "ssh-out"
      }
    ]
  },
  "outbounds": [
    {
      "tag": "ssh-out",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

# Simpler config: just forward any TCP from the inbound to 127.0.0.1:22
tee /usr/local/etc/xray/config.json > /dev/null <<EOF
{
  "inbounds": [
    {
      "port": $BACKEND_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "redirect": "127.0.0.1:22"
      }
    }
  ]
}
EOF

echo "[4/5] Writing nginx config..."
tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }

    # Optional: fake website on /
    root /var/www/html;
}
EOF

mkdir -p /var/www/html
echo "<html><body><h1>OK</h1></body></html>" > /var/www/html/index.html
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

echo "[5/5] Restarting services..."
nginx -t && systemctl restart nginx
systemctl restart xray
systemctl enable nginx xray

echo ""
echo "========== DONE =========="
echo "Domain: $DOMAIN"
echo "UUID:   $UUID"
echo "WS Path: $WS_PATH"
echo ""
echo "Connect with this SSH command:"
echo "ssh -o ProxyCommand=\"xray ws --server wss://$DOMAIN$WS_PATH --uuid $UUID\" user@$DOMAIN"
echo ""
echo "Make sure SSH on port 22 is running: systemctl status ssh"
