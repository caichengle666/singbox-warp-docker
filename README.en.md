# singbox-warp-docker

A Docker-based `sing-box` image template with:

- `HY2` inbound
- `VLESS` inbound
- Cloudflare WARP outbound
- Optional automatic TLS via Cloudflare DNS API
- GitHub Actions multi-architecture image builds

## Quick Start

1. Copy `.env.example` to `.env`
2. Fill values based on the `Required / Optional / Auto-managed` sections below
3. Run:

```bash
docker compose up -d
```

4. Check logs and generated node links:

```bash
docker compose logs -f
```

The command above uses the published image. To build from source, leave the version arguments empty to fetch the latest releases, or provide explicit versions, then replace `image` in `docker-compose.yml` with the local image:

```bash
docker build --build-arg SINGBOX_VERSION= --build-arg WGCF_VERSION= --build-arg ACME_SH_VERSION= -t singbox-warp-docker:local .
```

## Required Values

You must provide these values yourself, otherwise the container will not serve traffic correctly:

- `.env` `TLS_DOMAIN` is required for TLS and node link generation

The startup script injects `TLS_DOMAIN` into both inbound `tls.server_name` fields, so you usually do not need to edit the domain inside the template manually.

Additional required values for automatic TLS mode:

- `.env` `AUTO_TLS=true`
- `.env` `TLS_DOMAIN`
- `.env` `CF_Token=...`

`CF_Token` is only used for Cloudflare DNS API certificate automation, not for WARP registration.

Additional required files for manual certificate mode:

- `./certs/fullchain.pem`
- `./certs/privkey.pem`
- If either file is missing, the container exits early with a config error before starting `sing-box`

Optional existing WARP account reuse:

- Put your existing account file at `./data/wgcf-account.toml` before first start
- Do not bake WARP account files into the image or commit them into the repository

## Optional Values

These can be changed if needed, but the service can still start with defaults:

- `.env` `HY2_PORT`, default `32443`
- `.env` `VLESS_PORT`, default `38443`
- `.env` `MIXED_PORT`, default `1080` (**local HTTP+SOCKS5 proxy entry**, see next section)
- `.env` `AUTH_UUID`, shared value for `hy2 password` and `vless uuid`
- `.env` `HY2_PASSWORD`, override only `hy2 password`
- `.env` `VLESS_UUID`, override only `vless uuid`
- `.env` `ACME_EMAIL`
- `.env` `TLS_CERT_PATH`, default `/etc/sing-box/certs/fullchain.pem`
- `.env` `TLS_KEY_PATH`, default `/etc/sing-box/certs/privkey.pem`
- `.env` `TLS_ISSUE_RETRIES`, default `3`
- `.env` `TLS_RENEW_INTERVAL`, default `43200`
- `.env` `WARP_LICENSE_KEY`, optional, for WARP+ license binding
- `./data/wgcf-account.toml`, if you already have a WARP account file to reuse

## Local proxy entry (MIXED)

sing-box inside the container runs a **`mixed`-type inbound**. Docker maps it to the host **`127.0.0.1:1080`** by default, supporting both:

- **SOCKS5 proxy**: `socks5://127.0.0.1:1080`
- **HTTP CONNECT proxy**: `http://127.0.0.1:1080`

**All traffic exits through the WARP tunnel**, so the public egress IP is a Cloudflare edge node, **not** your server's own IP.

Common uses:

- **Local tooling proxy**: route `curl`, `git`, `apt`, etc. on the host through `127.0.0.1:1080`
  ```bash
  curl -x socks5://127.0.0.1:1080 https://api.ipify.org
  ```
- **SSH forwarding**: when remote temporary access is needed, forward to the host-local `1080` port over SSH

**Port change**: set `MIXED_PORT=xxxx` in `.env`; both container and host-local ports are updated together.

> ⚠️ **Security note**: port `1080` has no authentication and is mapped to `127.0.0.1` by default. Do not change it to `0.0.0.0` for public or LAN exposure.

## `.env` Examples

Two practical examples are provided below.

### Example 1: Manual certificate mode

```env
# Must change: HY2 port
HY2_PORT=32443

# Must change: VLESS port
VLESS_PORT=38443

# Optional: local HTTP+SOCKS5 proxy port (does not affect HY2/VLESS node usage)
MIXED_PORT=1080

# Recommended: fixed auth value. If empty, one UUID is generated at startup
AUTH_UUID=53fbb4a6-b0a1-4b0b-ae60-0b844c76580e

# Optional: overrides only HY2 password; if empty, falls back to AUTH_UUID
HY2_PASSWORD=

# Optional: overrides only VLESS UUID; if empty, falls back to AUTH_UUID
VLESS_UUID=

# Must confirm: manual certificate mode should use false
AUTO_TLS=false

# Recommended: used for node link generation; set your real domain
TLS_DOMAIN=1100.ccwu.cc

# Usually do not change
TLS_CERT_PATH=/etc/sing-box/certs/fullchain.pem
TLS_KEY_PATH=/etc/sing-box/certs/privkey.pem

# Not needed for manual certificate mode
ACME_EMAIL=

# Usually do not change
TLS_ISSUE_RETRIES=3
TLS_RENEW_INTERVAL=43200

# Optional: not needed for standard WARP; set only if you use WARP+
WARP_LICENSE_KEY=

# Not needed for manual certificate mode
CF_Token=
CF_Account_ID=
CF_Zone_ID=
```

Manual certificate mode also requires:

- `./certs/fullchain.pem`
- `./certs/privkey.pem`

### Example 2: Automatic TLS mode

```env
# Must change: HY2 port
HY2_PORT=32443

# Must change: VLESS port
VLESS_PORT=38443

# Optional: local HTTP+SOCKS5 proxy port (does not affect HY2/VLESS node usage)
MIXED_PORT=1080

# Recommended: fixed auth value. If empty, one UUID is generated at startup
AUTH_UUID=53fbb4a6-b0a1-4b0b-ae60-0b844c76580e

# Optional
HY2_PASSWORD=
VLESS_UUID=

# Must change: automatic TLS mode should use true
AUTO_TLS=true

# Must change: real domain already pointing to your VPS
TLS_DOMAIN=1100.ccwu.cc

# Usually do not change
TLS_CERT_PATH=/etc/sing-box/certs/fullchain.pem
TLS_KEY_PATH=/etc/sing-box/certs/privkey.pem

# Recommended: ACME account email
ACME_EMAIL=admin@1100.ccwu.cc

# Usually do not change
TLS_ISSUE_RETRIES=3
TLS_RENEW_INTERVAL=43200

# Optional: not needed for standard WARP; set only if you use WARP+
WARP_LICENSE_KEY=

# Must change: Cloudflare DNS API token
CF_Token=your_cloudflare_dns_token

# Optional: not required by the current script
CF_Account_ID=
CF_Zone_ID=
```

Automatic TLS mode notes:

- `TLS_DOMAIN` must already resolve to your VPS
- `CF_Token` must have DNS edit permission for the target zone
- Certificates are issued automatically and written into `./certs`

## Auto-managed Values

These values are generated or rendered by the startup script and usually should not be edited manually:

- All `__WARP_*__` placeholders in `config/sing-box.template.json`
- `__HY2_PORT__`
- `__VLESS_PORT__`
- `__HY2_PASSWORD__`
- `__VLESS_UUID__`
- `__TLS_DOMAIN__`
- `__TLS_CERT_PATH__`
- `__TLS_KEY_PATH__`

Default behavior:

- If `AUTH_UUID` / `HY2_PASSWORD` / `VLESS_UUID` are not provided, one UUID is generated at startup
- The generated UUID is used for both `hy2 password` and `vless uuid`
- If `./data/wgcf-account.toml` is not provided, the container auto-registers WARP on first start
- If `WARP_LICENSE_KEY` is provided, startup attempts to apply the WARP+ license and regenerate the profile

## Automatic TLS Prerequisites

- `TLS_DOMAIN` must be hosted on Cloudflare with correct DNS records
- `CF_Token` needs Zone DNS edit permission
- If first issue fails, check log lines containing `[tls]`

## WARP Credential Notes

- Standard WARP: no extra token is required; the container auto-registers on first start
- WARP+: optionally provide `.env` `WARP_LICENSE_KEY`
- `./data/wgcf-account.toml` and the rest of `./data` persist the WARP account and generated profile
- `CF_Token` is not a WARP token; it is only used for automatic TLS

## Persistent Directories

- `./data`: stores WARP registration and generated profile
- `./acme`: stores ACME account and renewal state
- `./certs`: stores TLS certificates

Keep secrets out of the repository:

- `wgcf-account.toml` should live under `./data`, which is already git-ignored
- Do not place real WARP credentials under `config/`

## Scripted Industrial Deployment

The repository includes `deploy.sh` for repeatable VPS deployment workflows.

Interactive one-command setup (recommended for a fresh VPS):

```bash
curl -fsSL https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh | bash
```

What this interactive script does:

- checks/installs Docker automatically (Debian/Ubuntu)
- asks for key settings interactively (ports/domain/TLS/WARP)
- writes `docker-compose.yml` and `.env`
- pulls image, starts container, and runs health checks

## Runtime Safety

- Basic resource limits are set in `docker-compose.yml`: `mem_limit=512m`, `pids_limit=256`
- Healthcheck is enabled for the `sing-box` main process
- `.env` is ignored by git
- The main service is `sing-box`; certificate renewal is handled by a lightweight shell loop with signal forwarding and graceful shutdown

## Template Notes

File used: `config/sing-box.template.json`

This is a template, not the final runtime config. On startup the script injects:

- HY2 port / password
- VLESS port / UUID
- TLS certificate path and server name
- WARP outbound parameters
- `MIXED` inbound port

Relationship between the 3 inbounds in the template:

| Type | Purpose | Client |
|---|---|---|
| `hysteria2` | External node egress | HY2 client (self-use or share) |
| `vless` | External node egress | v2rayN/Nekoray etc. (self-use or share) |
| `mixed` | **Local HTTP+SOCKS5 proxy** | Host tools, Cloudflare Tunnel forwarding |

`mixed` does not need password or TLS — it only listens inside the container (`0.0.0.0:1080`) and traffic is immediately handled by the WARP outbound.

In most cases you mainly need to care about:

- whether the template structure matches your protocol needs
- whether you want additional custom route rules

Template example:

```json
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": __HY2_PORT__,
      "users": [
        {
          "password": "__HY2_PASSWORD__"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "__TLS_DOMAIN__",
        "certificate_path": "__TLS_CERT_PATH__",
        "key_path": "__TLS_KEY_PATH__"
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": __VLESS_PORT__,
      "users": [
        {
          "uuid": "__VLESS_UUID__"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "__TLS_DOMAIN__",
        "certificate_path": "__TLS_CERT_PATH__",
        "key_path": "__TLS_KEY_PATH__"
      }
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": __MIXED_PORT__
    }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp",
      "server": "__WARP_PEER_HOST__",
      "server_port": __WARP_PEER_PORT__,
      "local_address": [
        "__WARP_ADDRESS_V4__",
        "__WARP_ADDRESS_V6__"
      ],
      "private_key": "__WARP_PRIVATE_KEY__",
      "peer_public_key": "__WARP_PEER_PUBLIC_KEY__",
      "reserved": [0, 0, 0],
      "mtu": 1280
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "warp"
  }
}
```

## GitHub Build Notes

- The workflow checks versions on `push`, manual trigger, and scheduled runs
- It only builds when `sing-box` or `wgcf` versions actually change
- Images are pushed to `ghcr.io/<owner>/singbox-warp-docker`

## Security Notes

- Do not commit private keys, certificates, or `.env` into the repository
- When using automatic TLS, keep `CF_Token` scoped to minimum required permissions
