# MeshNet — Local Testing Guide

Test the full MeshNet stack on your LAN without a VPS.

## Prerequisites

- **Docker Desktop** running on the server Mac
- **Tailscale client** installed on each machine (`brew install tailscale`)
- All machines on the **same Wi-Fi / LAN**

## Quick Start

```bash
# 1. Start the stack (auto-detects LAN IP, sets up /etc/hosts, prints all credentials)
bash scripts/test-local.sh

# 2. Connect this Mac using the command printed by the script
sudo tailscaled &  # if not already running
sudo tailscale up --login-server=http://vpn.local:9080 --authkey=<KEY_FROM_OUTPUT>

# 3. Open the Admin UI
#    https://vpn.local:8443/admin/
#    Paste the API Key and set Headscale URL to https://vpn.local
```

## Connect Another Machine

```bash
# On the other machine:
sudo sh -c 'echo "<SERVER_LAN_IP> vpn.local" >> /etc/hosts'
sudo tailscale up --login-server=http://vpn.local:9080 --authkey=<KEY_FROM_OUTPUT>
```

Or generate a new pre-auth key anytime:
```bash
bash scripts/test-local.sh --add-client
```

## Verify Mesh Connectivity

```bash
# Check all nodes
bash scripts/test-local.sh --status

# Ping another node by mesh IP
tailscale ping 100.64.0.2

# Ping by MagicDNS name
ping macbookpro.admin.mesh
```

## Commands

| Command | Description |
|---------|-------------|
| `bash scripts/test-local.sh` | Start stack, print all credentials |
| `bash scripts/test-local.sh --status` | Show nodes, connections, containers |
| `bash scripts/test-local.sh --add-client` | Generate a new pre-auth key |
| `bash scripts/test-local.sh --down` | Stop containers |
| `bash scripts/test-local.sh --clean` | Stop containers + delete volumes |

## What Gets Tested

- Headscale control plane (user/node management)
- Admin UI (dashboard, API key auth)
- Tailscale client registration (pre-auth keys)
- WireGuard P2P mesh between nodes
- MagicDNS resolution (`.mesh` TLD)
- STUN/NAT traversal

## Limitations

- **Self-signed TLS** — browsers show a warning, Tailscale clients must use HTTP (`http://vpn.local:9080`)
- **DERP relay** — may show a health warning; P2P direct connections work fine on the same LAN
- **Mobile clients** — iOS/Android Tailscale apps require valid TLS, so they need a real VPS deployment
- **LAN only** — clients must be on the same network as the server Mac
