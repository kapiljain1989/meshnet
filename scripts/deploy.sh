#!/usr/bin/env bash
###############################################################################
# MeshNet — VPS Bootstrap Script
# Run on a fresh Ubuntu 22.04/24.04 VPS as root or with sudo.
#
# Usage: sudo bash scripts/deploy.sh
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[MeshNet]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Preflight Checks ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err "Run as root: sudo bash $0"
[[ -f .env ]] || err ".env file not found. Run: cp .env.example .env && nano .env"

source .env
[[ -n "${HEADSCALE_DOMAIN:-}" ]] || err "HEADSCALE_DOMAIN not set in .env"
[[ -n "${UI_DOMAIN:-}" ]]       || err "UI_DOMAIN not set in .env"

PUBLIC_IP=$(curl -4 -sf https://ifconfig.me || curl -4 -sf https://api.ipify.org)
[[ -n "$PUBLIC_IP" ]] || err "Could not detect public IP"
log "Detected public IP: $PUBLIC_IP"

# ─── Step 1: System Packages ────────────────────────────────────────────────
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git ufw apt-transport-https ca-certificates gnupg lsb-release jq sqlite3

# ─── Step 2: Install Docker ─────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    log "Docker installed: $(docker --version)"
else
    log "Docker already installed: $(docker --version)"
fi

# ─── Step 3: Firewall (UFW) ─────────────────────────────────────────────────
log "Configuring firewall..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP (Caddy ACME challenge)"
ufw allow 443/tcp   comment "HTTPS (Caddy TLS)"
ufw allow 443/udp   comment "HTTP/3 QUIC"
ufw allow 3478/udp  comment "STUN (DERP NAT traversal)"

ufw --force enable
log "Firewall configured. Open ports: 22, 80, 443, 3478/udp"

# ─── Step 4: Kernel Hardening ───────────────────────────────────────────────
log "Applying kernel hardening..."
cat > /etc/sysctl.d/99-meshnet.conf << 'SYSCTL'
# Disable IP forwarding (the VPS is a control plane, not a router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Ignore source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
SYSCTL
sysctl --system >/dev/null 2>&1

# ─── Step 5: Patch Headscale Config ─────────────────────────────────────────
log "Patching Headscale config with domain=$HEADSCALE_DOMAIN, IP=$PUBLIC_IP..."
sed -i "s|HEADSCALE_DOMAIN_PLACEHOLDER|${HEADSCALE_DOMAIN}|g" config/headscale/config.yaml
sed -i "s|SERVER_PUBLIC_IP_PLACEHOLDER|${PUBLIC_IP}|g" config/headscale/config.yaml

# ─── Step 6: Generate UI Basic Auth Password ────────────────────────────────
if grep -q 'YourBcryptHashHere' config/caddy/Caddyfile; then
    log "Generating admin password for UI..."
    UI_PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
    BCRYPT_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$UI_PASSWORD" 2>/dev/null)
    # Escape special characters for sed
    ESCAPED_HASH=$(printf '%s\n' "$BCRYPT_HASH" | sed 's/[&/\$]/\\&/g')
    sed -i "s|\\\$2a\\\$14\\\$YourBcryptHashHere|${ESCAPED_HASH}|g" config/caddy/Caddyfile

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW} SAVE THESE CREDENTIALS — SHOWN ONLY ONCE${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " UI URL:      https://${UI_DOMAIN}"
    echo -e " Username:    admin"
    echo -e " Password:    ${UI_PASSWORD}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

# ─── Step 7: Launch Containers ───────────────────────────────────────────────
log "Pulling images..."
docker compose pull

log "Starting MeshNet stack..."
docker compose up -d

# Wait for headscale to be healthy
log "Waiting for Headscale to become healthy..."
for i in $(seq 1 30); do
    if docker inspect --format='{{.State.Health.Status}}' meshnet-headscale 2>/dev/null | grep -q healthy; then
        break
    fi
    sleep 2
done

if ! docker inspect --format='{{.State.Health.Status}}' meshnet-headscale 2>/dev/null | grep -q healthy; then
    warn "Headscale not healthy after 60s. Check: docker logs meshnet-headscale"
fi

# ─── Step 8: Create Initial User & API Key ───────────────────────────────────
log "Creating default mesh user 'admin'..."
docker exec meshnet-headscale headscale users create admin 2>/dev/null || true

log "Generating API key for Headscale-UI..."
API_KEY=$(docker exec meshnet-headscale headscale apikeys create --expiration 90d 2>/dev/null | tail -1)

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} MESHNET DEPLOYED SUCCESSFULLY${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e " Control Plane:  https://${HEADSCALE_DOMAIN}"
echo -e " Admin UI:       https://${UI_DOMAIN}"
echo -e " Public IP:      ${PUBLIC_IP}"
echo ""
echo -e " Headscale API Key (paste into UI settings):"
echo -e " ${YELLOW}${API_KEY}${NC}"
echo ""
echo -e " To connect a client:"
echo -e "   tailscale up --login-server=https://${HEADSCALE_DOMAIN}"
echo ""
echo -e " Useful commands:"
echo -e "   docker exec meshnet-headscale headscale users list"
echo -e "   docker exec meshnet-headscale headscale nodes list"
echo -e "   docker exec meshnet-headscale headscale preauthkeys create --user admin --expiration 1h"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ─── Step 9: Backup Cron ────────────────────────────────────────────────────
log "Setting up daily SQLite backup..."
mkdir -p /opt/meshnet/backups

cat > /etc/cron.daily/meshnet-backup << 'CRON'
#!/bin/bash
BACKUP_DIR="/opt/meshnet/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
VOLUME_PATH=$(docker volume inspect meshnet-headscale-data --format '{{ .Mountpoint }}')

# SQLite online backup (safe while headscale is running)
sqlite3 "${VOLUME_PATH}/db.sqlite" ".backup '${BACKUP_DIR}/db_${TIMESTAMP}.sqlite'"

# Keep only last 7 daily backups
find "$BACKUP_DIR" -name "db_*.sqlite" -mtime +7 -delete

logger -t meshnet-backup "Backup completed: db_${TIMESTAMP}.sqlite"
CRON
chmod +x /etc/cron.daily/meshnet-backup
log "Daily backup configured at /opt/meshnet/backups/"