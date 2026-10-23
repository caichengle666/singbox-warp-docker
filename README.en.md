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
docker build --build-arg SINGBOX_VERSION= --build-arg WGCF_VERSION= -t singbox-warp-docker:local .
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
- `.env` `ENABLE_HY2`, default `true`
- `.env` `ENABLE_VLESS`, default `true`
- `.env` `ENABLE_ANYTLS`, default `false`
- `.env` `ENABLE_SS`, default `false`
- `.env` `ANYTLS_PORT`, default `4443`
- `.env` `SS_PORT`, default `48443`
- `.env` `HY2_PORT_HOPPING`, default `false`; the deploy script maps the HY2 UDP hop ports when enabled
- `.env` `HY2_HOP_PORTS`, auto-selected from up to 50 consecutive free ports when left empty
- `.env` `AUTH_UUID`, shared value for `hy2 password` and `vless uuid`
- `.env` `HY2_PASSWORD`, override only `hy2 password`
- `.env` `VLESS_UUID`, override only `vless uuid`
- `.env` `ACME_EMAIL`
- `.env` `TLS_CERT_PATH`, default `/etc/sing-box/certs/fullchain.pem`
- `.env` `TLS_KEY_PATH`, default `/etc/sing-box/certs/privkey.pem`
- `.env` `TLS_ISSUE_RETRIES`, default `3`
- `.env` `TLS_RENEW_INTERVAL`, default `43200`
- `.env` `WARP_LICENSE_KEY`, optional, for WARP+ license binding
- `.env` `NODE_NAME`, optional; auto-generated from IP/city when left empty
- `.env` `WARP_MODE`, default `auto`; one of `auto` / `usque` / `wireguard` / `direct`
- `.env` `WARP_AUTORECOVER`, default `true`; stays on direct while WARP is down, switches back automatically once it recovers
- `.env` `WARP_PROBE_INTERVAL`, default `60` (seconds), WARP health-check interval. The active egress is only abandoned after 3 consecutive failed probes (rechecked every 10s), so a blip doesn't drop every connection; while on direct, retries back off from the interval, doubling up to 15 minutes; a failed usque registration is not retried for 1 hour
- `.env` `USQUE_HTTP2`, default `true`; usque uses MASQUE over HTTP/2 (TCP 443)
- `./data/wgcf-account.toml`, if you already have a WARP account file to reuse

## Local proxy entry (MIXED)

sing-box inside the container runs a **`mixed`-type inbound**. Docker maps it to the host **`127.0.0.1:1080`** by default, supporting both:

- **SOCKS5 proxy**: `socks5://127.0.0.1:1080`
- **HTTP CONNECT proxy**: `http://127.0.0.1:1080`

**While WARP is available all traffic exits through the WARP tunnel**, so the public egress IP is a Cloudflare edge node, **not** your server's own IP.

If WARP is unavailable (for example when outbound UDP is blocked by the platform), the route falls back to direct so the node keeps working, and switches back automatically once WARP recovers.

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
- Generated `AUTH_UUID` / `SS_PASSWORD` values are saved to `./data/credentials.env` and survive restarts; delete that file to regenerate them
- The startup log prints node links for each enabled protocol (`[node] hy2://...`)
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

File used: `config/sing-box.template.json` (the file is authoritative; this section only describes its shape).

This is a template, not the final runtime config. On startup the script injects ports, passwords/UUIDs, TLS paths and server name, WARP WireGuard parameters and the `MIXED` port, drops disabled inbounds, and runs `sing-box check` on the result.

- Inbounds: HY2, VLESS, AnyTLS, Shadowsocks 2022 (kept per `ENABLE_*`), `mixed-in` (host-local proxy), and the container-internal `warp-probe` (127.0.0.1:18080, used to probe WARP)
- Outbounds: `warp` (WireGuard endpoint), `usque` (MASQUE SOCKS on 127.0.0.1:18081), `direct`
- Route rules:
  1. `warp-probe` always goes to `warp`
  2. Connections to private/internal addresses (including the `169.254.169.254` cloud metadata service and container loopback) are rejected, so a node cannot be used to reach the server's internal network
  3. Everything else uses `route.final`, which the entrypoint switches between `usque` / `warp` / `direct`

Add custom rules after rule 2 and leave `route.final` to the script.

## GitHub Build Notes

- The workflow runs on `push`, manual trigger, and a daily schedule
- Every run renders the template and runs `sing-box check` with the latest `sing-box`; a failure stops the build and push
- On `push` it only builds when code/config changed; on schedule it only builds when `sing-box` or `wgcf` has a new release
- Images are pushed to `ghcr.io/<owner>/singbox-warp-docker`

## Security Notes

- Do not commit private keys, certificates, or `.env` into the repository
- When using automatic TLS, keep `CF_Token` scoped to minimum required permissions
