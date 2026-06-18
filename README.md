# MeshNet

Self-hosted mesh VPN built on [Headscale](https://github.com/juanfont/headscale) (open-source Tailscale control plane), [Caddy](https://caddyserver.com/) (reverse proxy + auto TLS), and [WireGuard](https://www.wireguard.com/) (encrypted tunnels).

Deploy on a single Ubuntu VPS. Connect any device running the Tailscale client — macOS, Linux, Windows, iOS, Android. Nodes communicate directly via WireGuard P2P, falling back to an embedded DERP relay when NAT prevents direct connections.

## Architecture

```
                        Internet
                           |
                  +--------+--------+
                  |   Ubuntu VPS    |
                  |                 |
  :80,:443 ------+|    Caddy       |  <-- TLS termination
                  |      |         |
                  |  Headscale     |  <-- Control plane + DERP relay
                  |      |         |
  :3478/udp -----+|   (STUN)      |
                  |                 |
                  |  Admin UI      |  <-- Web dashboard
                  +-----------------+

  Client A <------ WireGuard P2P ------> Client B
       |                                      |
       +------ DERP relay (fallback) ---------+
```

## Quick Start

### Production (VPS)

```bash
ssh root@<VPS_IP>
git clone https://github.com/kapiljain1989/meshnet.git /opt/meshnet
cd /opt/meshnet
cp .env.example .env    # set HEADSCALE_DOMAIN, UI_DOMAIN, ACME_EMAIL
sudo bash scripts/deploy.sh
```

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for full instructions.

### Local Testing (no VPS needed)

```bash
bash scripts/test-local.sh
```

Starts the full stack on your LAN with self-signed TLS. Prints credentials, pre-auth keys, and copy-paste commands for connecting clients.

See [LOCAL_TESTING.md](LOCAL_TESTING.md) for details.

## Connect a Client

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your MeshNet
sudo tailscale up --login-server=https://hs.yourdomain.com
```

## Project Structure

```
docker-compose.yml              # Production stack (3 services)
docker-compose.local.yml        # Local testing override
.env.example                    # Required environment variables
config/
  caddy/Caddyfile               # Reverse proxy + TLS config
  caddy/Caddyfile.local         # Local testing (self-signed TLS)
  headscale/config.yaml         # Headscale control plane config
  headscale/config.yaml.local   # Local testing (localhost)
  headscale/acl.yaml            # Access control policy
scripts/
  deploy.sh                     # VPS bootstrap (Docker, firewall, certs)
  test-local.sh                 # Local test runner
```

## Key Features

- **Fully self-hosted** — no data passes through Tailscale's servers
- **Automatic TLS** — Caddy provisions Let's Encrypt certificates
- **Embedded DERP relay** — fallback when P2P fails, on your own server
- **MagicDNS** — nodes get names like `laptop.admin.mesh`
- **ACL policies** — control which nodes can talk to each other
- **Web admin UI** — manage users, nodes, and API keys
- **Daily backups** — automated SQLite backups with 7-day retention

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 80 | TCP | ACME HTTP-01 challenge |
| 443 | TCP+UDP | HTTPS + HTTP/3 |
| 3478 | UDP | STUN (NAT traversal) |

## License

Private repository.
