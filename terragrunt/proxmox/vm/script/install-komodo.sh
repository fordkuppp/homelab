#!/bin/bash
set -e

# Make sure docker compose will have directory to mount
mkdir -p /mnt/nas_temp
mount -t nfs 192.168.1.11:/mnt/general/data /mnt/nas_temp
mkdir -p /mnt/nas_temp/komodo/backups
umount /mnt/nas_temp
rmdir /mnt/nas_temp

mkdir -p /opt/komodo
cd /opt/komodo

cat <<'EOF' > docker-compose.yml
${compose_content}
EOF
cat <<'EOF' > compose.env
${env_content}
EOF

# Periphery call for HOME env var
export HOME=/home/ubuntu
curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py -o /tmp/setup-periphery.py
python3 /tmp/setup-periphery.py
systemctl enable --now periphery
docker compose up -d