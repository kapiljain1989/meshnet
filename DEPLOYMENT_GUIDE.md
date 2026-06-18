# MeshNet — Deployment Guide

Self-hosted mesh VPN on a single Ubuntu VPS using Headscale + Caddy + WireGuard.

---

## Prerequisites

- **Ubuntu VPS** (22.04 or 24.04, 1 vCPU / 1GB RAM minimum)
- **Domain name** with DNS access (e.g., `yourdomain.com`)
- **SSH access** to the VPS as root or sudo user

## Step 1: DNS Records

Create two A records pointing to your VPS public IP:

```
hs.yourdomain.com  →  A  →  <VPS_PUBLIC_IP>
ui.yourdomain.com  →  A  →  <VPS_PUBLIC_IP>
```

Wait for DNS propagation (verify with `dig hs.yourdomain.com`).

## Step 2: Clone & Configure

```bash
ssh root@<VPS_PUBLIC_IP>

git clone <your-repo-url> /opt/meshnet
cd /opt/meshnet

cp .env.example .env
nano .env
```

Fill in your values:
```
HEADSCALE_DOMAIN=hs.yourdomain.com
UI_DOMAIN=ui.yourdomain.com
ACME_EMAIL=you@yourdomain.com
```

## Step 3: Deploy

```bash
chmod +x scripts/deploy.sh
sudo bash scripts/deploy.sh
```

The script will:
1. Install Docker and configure UFW firewall
2. Patch configs with your domain and public IP
3. Generate a UI admin password (displayed once — save it)
4. Start all containers
5. Create an `admin` user and API key
6. Set up daily SQLite backups

## Step 4: Configure the UI

1. Open `https://ui.yourdomain.com` in your browser
2. Log in with the credentials shown by the deploy script
3. Go to **Settings** and paste the **Headscale API Key** shown by the deploy script
4. Set the **Headscale URL** to `https://hs.yourdomain.com`

## Step 5: Connect Clients

### macOS / Linux
```bash
# Install Tailscale client
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your MeshNet (not Tailscale's servers)
sudo tailscale up --login-server=https://hs.yourdomain.com
```

### Windows
1. Install Tailscale from https://tailscale.com/download
2. Open Registry Editor, navigate to `HKLM\SOFTWARE\Tailscale IPN`
3. Create string value `UnattendedMode` = `always`
4. Create string value `LoginURL` = `https://hs.yourdomain.com`
5. Restart Tailscale service, then log in

### iOS / Android
1. Install Tailscale from App Store / Play Store
2. Open the app and use the alternate server option or use the pre-auth key method below

### Using Pre-Auth Keys (all platforms)
```bash
# Generate a pre-auth key on the server
docker exec meshnet-headscale headscale preauthkeys create --user admin --expiration 1h

# On the client
sudo tailscale up --login-server=https://hs.yourdomain.com --authkey=<KEY>
```

## Step 6: Approve Nodes

After a client connects, approve it on the server:

```bash
# List pending nodes
docker exec meshnet-headscale headscale nodes list

# Approve a node (if not using pre-auth keys)
docker exec meshnet-headscale headscale nodes register --user admin --key nodekey:<KEY>
```

---

## Architecture Diagram

```
                          Internet
                             │
                    ┌────────┴────────┐
                    │   Ubuntu VPS     │
                    │                  │
    :80,:443 ──────▶│  ┌────────────┐ │
                    │  │   Caddy    │ │  ← TLS termination
                    │  └─────┬──────┘ │
                    │        │        │
                    │  ┌─────▼──────┐ │
                    │  │ Headscale  │ │  ← Control plane
                    │  │ + DERP     │ │  ← Embedded relay
                    │  └────────────┘ │
    :3478/udp ─────▶│  (STUN)        │
                    │                  │
                    │  ┌────────────┐ │
                    │  │ Headscale  │ │  ← Admin dashboard
                    │  │ UI         │ │
                    │  └────────────┘ │
                    │                  │
                    │  br-meshnet      │  ← Isolated Docker bridge
                    └─────────────────┘

    Client A ◄────── WireGuard P2P ──────► Client B
         │                                      │
         └───── DERP relay (fallback) ──────────┘
                  via VPS :443
```

## Port Reference

| Port | Protocol | Purpose | Exposed To |
|------|----------|---------|-----------|
| 22 | TCP | SSH | Internet (restrict to your IP if possible) |
| 80 | TCP | ACME HTTP-01 challenge | Internet |
| 443 | TCP+UDP | HTTPS + HTTP/3 (Headscale, UI, DERP) | Internet |
| 3478 | UDP | STUN (NAT traversal) | Internet |
| 8080 | TCP | Headscale HTTP | Docker internal only |
| 50443 | TCP | Headscale gRPC | Docker internal only |
| 9090 | TCP | Prometheus metrics | Docker internal only |

## Common Operations

### Create a new user
```bash
docker exec meshnet-headscale headscale users create <username>
```

### List all nodes
```bash
docker exec meshnet-headscale headscale nodes list
```

### Remove a node
```bash
docker exec meshnet-headscale headscale nodes delete --identifier <ID>
```

### Rotate API key
```bash
docker exec meshnet-headscale headscale apikeys create --expiration 90d
# Paste new key into UI settings
```

### View logs
```bash
docker logs meshnet-headscale --tail 50 -f
docker logs meshnet-caddy --tail 50 -f
```

### Manual backup
```bash
VOLUME=$(docker volume inspect meshnet-headscale-data --format '{{ .Mountpoint }}')
sqlite3 "$VOLUME/db.sqlite" ".backup '/opt/meshnet/backups/manual_$(date +%s).sqlite'"
```

### Restore from backup
```bash
docker compose down
VOLUME=$(docker volume inspect meshnet-headscale-data --format '{{ .Mountpoint }}')
cp /opt/meshnet/backups/<backup_file>.sqlite "$VOLUME/db.sqlite"
docker compose up -d
```

### Update Headscale
```bash
# Edit docker-compose.yml to bump image tag
docker compose pull
docker compose up -d
```

## Security Hardening Checklist

- [ ] Change default UI password (`caddy hash-password` and update Caddyfile)
- [ ] Restrict SSH to key-only auth (`PasswordAuthentication no` in sshd_config)
- [ ] Restrict SSH to your IP in UFW (`ufw allow from <YOUR_IP> to any port 22`)
- [ ] Enable automatic security updates (`apt install unattended-upgrades`)
- [ ] Set up fail2ban for SSH (`apt install fail2ban`)
- [ ] Rotate Headscale API keys every 90 days
- [ ] Review ACL policy (`config/headscale/acl.yaml`) as your mesh grows
- [ ] Enable OIDC/SSO when you have 5+ users (see config.yaml OIDC section)

## MagicDNS

With MagicDNS enabled (`.mesh` TLD), every node gets a DNS name:

```
laptop.admin.mesh       →  100.64.0.1
server.admin.mesh       →  100.64.0.2
phone.admin.mesh        →  100.64.0.3
```

These names resolve automatically on any connected Tailscale client.