# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

MeshNet is an infrastructure-as-code project that deploys a fully self-hosted mesh VPN on a single Ubuntu VPS. It uses Headscale (open-source Tailscale control plane), Caddy (reverse proxy + automatic TLS), and Headscale-UI (admin dashboard), all orchestrated via Docker Compose.

Clients connect using standard Tailscale apps pointed at the self-hosted control plane instead of Tailscale's servers. WireGuard handles the actual encrypted tunnels; Headscale coordinates key exchange and node registration.

## Architecture

Three containers on an isolated Docker bridge network (`br-meshnet`, `172.28.0.0/24`):

- **Caddy** (ports 80/443) — TLS termination, reverse proxies to Headscale (`:8080`) and UI (`:80`). Only internet-facing HTTP(S) entrypoint.
- **Headscale** (internal `:8080`, `:50443` gRPC, `:9090` metrics; external `:3478/udp` STUN) — control plane + embedded DERP relay. SQLite database at `/var/lib/headscale/db.sqlite` in a named volume.
- **Headscale-UI** (internal `:80`) — read-only container, talks to Headscale via the API key configured in its settings page.

Caddy terminates TLS for two domains: `HEADSCALE_DOMAIN` (control plane API) and `UI_DOMAIN` (admin dashboard with basic auth). The UI domain is protected by bcrypt basic auth configured in the Caddyfile.

## Config Files with Placeholders

`scripts/deploy.sh` patches these placeholders at deploy time via `sed`:
- `config/headscale/config.yaml`: `HEADSCALE_DOMAIN_PLACEHOLDER` and `SERVER_PUBLIC_IP_PLACEHOLDER`
- `config/caddy/Caddyfile`: `$2a$14$YourBcryptHashHere` (replaced with generated bcrypt hash)

These are one-shot replacements — once deployed, the files contain real values. When editing configs locally, leave placeholders intact if the change will go through `deploy.sh`.

## Deployment

```bash
# On VPS as root, from /opt/meshnet:
cp .env.example .env   # fill in HEADSCALE_DOMAIN, UI_DOMAIN, ACME_EMAIL
sudo bash scripts/deploy.sh
```

The deploy script installs Docker, configures UFW, patches configs, generates a UI password, starts containers, creates the `admin` user, generates an API key, and sets up daily SQLite backups. Credentials are displayed once during deploy and not persisted.

## Common Operations (all via `docker exec`)

```bash
docker exec meshnet-headscale headscale users list
docker exec meshnet-headscale headscale nodes list
docker exec meshnet-headscale headscale preauthkeys create --user admin --expiration 1h
docker exec meshnet-headscale headscale apikeys create --expiration 90d
docker logs meshnet-headscale --tail 50 -f
docker logs meshnet-caddy --tail 50 -f
```

## Key Design Decisions

- **No public DERP servers** — `derp.urls` is empty in `config.yaml`; all relay traffic stays on the self-hosted DERP server (region 999).
- **gRPC insecure internally** — `grpc_allow_insecure: true` is safe because gRPC (`:50443`) is only reachable inside the Docker network; Caddy handles external TLS.
- **IP forwarding disabled** — the VPS is a control plane, not a router. Sysctl hardening is applied by `deploy.sh`.
- **ACL starts permissive** — `acl.yaml` allows all-to-all; SSH ACLs are defined but groups are empty until populated.
- **Sequential IP allocation** — nodes get IPs from `100.64.0.0/10` (CGNAT range matching Tailscale). MagicDNS uses `.mesh` TLD.