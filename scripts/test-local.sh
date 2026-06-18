#!/usr/bin/env bash
###############################################################################
# MeshNet — Local Test Runner
# Starts the full stack on your LAN with self-signed TLS.
#
# Usage:
#   bash scripts/test-local.sh              # Start stack + print credentials
#   bash scripts/test-local.sh --down       # Tear everything down
#   bash scripts/test-local.sh --clean      # Tear down + remove volumes
#   bash scripts/test-local.sh --add-client # Generate a new pre-auth key
#   bash scripts/test-local.sh --status     # Show node/connection status
###############################################################################

set -euo pipefail

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.local.yml"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[MeshNet]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Satisfy the base docker-compose.yml required variable checks
export HEADSCALE_DOMAIN=localhost
export UI_DOMAIN=localhost
export ACME_EMAIL=local@test.com

# ─── Detect LAN IP ─────────────────────────────────────────────────────────
get_lan_ip() {
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1"
}

# ─── Subcommands ───────────────────────────────────────────────────────────
case "${1:-}" in
    --down)
        log "Stopping containers..."
        $COMPOSE down
        log "Done."
        exit 0
        ;;
    --clean)
        log "Stopping containers and removing volumes..."
        $COMPOSE down -v
        log "Done."
        exit 0
        ;;
    --add-client)
        KEY=$(docker exec meshnet-headscale headscale preauthkeys create --user admin --expiration 1h 2>&1 | tail -1)
        LAN_IP=$(get_lan_ip)
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN} NEW CLIENT PRE-AUTH KEY (expires in 1 hour)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e " Pre-Auth Key: ${YELLOW}${KEY}${NC}"
        echo ""
        echo -e " On the client machine, run:"
        echo -e "   ${CYAN}1.${NC} sudo sh -c 'echo \"${LAN_IP} vpn.local\" >> /etc/hosts'"
        echo -e "   ${CYAN}2.${NC} sudo tailscale up --login-server=http://vpn.local:9080 --authkey=${KEY}"
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 0
        ;;
    --status)
        echo ""
        echo -e "${CYAN}── Registered Nodes ──${NC}"
        docker exec meshnet-headscale headscale nodes list 2>&1
        echo ""
        echo -e "${CYAN}── Tailscale Status (this machine) ──${NC}"
        tailscale status 2>&1 || warn "Tailscale not running on this machine"
        echo ""
        echo -e "${CYAN}── Container Status ──${NC}"
        $COMPOSE ps 2>&1
        exit 0
        ;;
esac

# ─── Preflight ──────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || err "Docker is not installed"
docker info >/dev/null 2>&1     || err "Docker daemon is not running"

LAN_IP=$(get_lan_ip)
log "Detected LAN IP: $LAN_IP"

# ─── Check /etc/hosts ──────────────────────────────────────────────────────
if ! grep -q "vpn.local" /etc/hosts 2>/dev/null; then
    warn "vpn.local not found in /etc/hosts. Adding it..."
    sudo sh -c "echo '${LAN_IP} vpn.local' >> /etc/hosts"
    log "Added '${LAN_IP} vpn.local' to /etc/hosts"
fi

# ─── Patch local configs with LAN IP ──────────────────────────────────────
sed -i '' "s|ipv4: .*|ipv4: ${LAN_IP}|" config/headscale/config.yaml.local

# ─── Start ──────────────────────────────────────────────────────────────────
log "Pulling images..."
$COMPOSE pull --quiet

log "Starting MeshNet stack..."
$COMPOSE up -d

# ─── Wait for Headscale ────────────────────────────────────────────────────
log "Waiting for Headscale to become healthy..."
for i in $(seq 1 30); do
    if docker inspect --format='{{.State.Health.Status}}' meshnet-headscale 2>/dev/null | grep -q healthy; then
        break
    fi
    sleep 2
done

if ! docker inspect --format='{{.State.Health.Status}}' meshnet-headscale 2>/dev/null | grep -q healthy; then
    err "Headscale not healthy after 60s. Check: docker logs meshnet-headscale"
fi

# ─── Create admin user, API key, and pre-auth keys ─────────────────────────
log "Setting up admin user..."
docker exec meshnet-headscale headscale users create admin 2>/dev/null || true

log "Generating credentials..."
API_KEY=$(docker exec meshnet-headscale headscale apikeys create --expiration 90d 2>/dev/null | tail -1)
SERVER_KEY=$(docker exec meshnet-headscale headscale preauthkeys create --user admin --expiration 1h 2>/dev/null | tail -1)
CLIENT_KEY=$(docker exec meshnet-headscale headscale preauthkeys create --user admin --expiration 1h 2>/dev/null | tail -1)

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} MESHNET LOCAL STACK IS RUNNING${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e " ${CYAN}Server LAN IP:${NC}  $LAN_IP"
echo ""
echo -e " ${CYAN}── URLs ──${NC}"
echo -e " Headscale API:  http://vpn.local:9080"
echo -e " Admin UI:       https://vpn.local:8443/admin/"
echo ""
echo -e " ${CYAN}── UI Settings ──${NC}"
echo -e " Headscale URL:  https://vpn.local"
echo -e " API Key:        ${YELLOW}${API_KEY}${NC}"
echo ""
echo -e " ${CYAN}── Connect This Mac ──${NC}"
echo -e " sudo tailscale up --login-server=http://vpn.local:9080 --authkey=${SERVER_KEY}"
echo ""
echo -e " ${CYAN}── Connect Another Machine ──${NC}"
echo -e " Step 1: Add hosts entry on that machine:"
echo -e "   sudo sh -c 'echo \"${LAN_IP} vpn.local\" >> /etc/hosts'"
echo -e " Step 2: Connect:"
echo -e "   sudo tailscale up --login-server=http://vpn.local:9080 --authkey=${CLIENT_KEY}"
echo ""
echo -e " ${CYAN}── Generate More Client Keys ──${NC}"
echo -e " bash scripts/test-local.sh --add-client"
echo ""
echo -e " ${CYAN}── Other Commands ──${NC}"
echo -e " bash scripts/test-local.sh --status     # Show nodes & status"
echo -e " bash scripts/test-local.sh --down       # Stop stack"
echo -e " bash scripts/test-local.sh --clean      # Stop + remove data"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
