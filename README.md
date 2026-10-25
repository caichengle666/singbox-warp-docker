# singbox-warp-docker

Documentation:

- Chinese: [README.zh-CN.md](README.zh-CN.md)
- English: [README.en.md](README.en.md)

This repository builds a Docker image for `sing-box` with:

- `HY2` inbound
- `VLESS` inbound (TLS or Reality)
- Optional `AnyTLS`, `Shadowsocks 2022` and `TUIC v5` inbounds
- Tunnel mode: VLESS-WS behind `cloudflared` for hosts with no inbound ports (`docker-compose.tunnel.yml`)
- WARP for everything, or only for selected sites (`WARP_SCOPE=split`)
- `MIXED` (HTTP+SOCKS5) host-local proxy on `127.0.0.1:1080` by default — traffic exits through WARP
- Cloudflare WARP outbound
- Optional automatic TLS via Cloudflare DNS API
- GitHub Actions multi-arch image build

If you want to reuse an existing WARP account, place `wgcf-account.toml` at `./data/wgcf-account.toml` before first start. Avoid putting real WARP credentials under `config/` or baking them into the image.
