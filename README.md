# singbox-warp-docker

Documentation:

- Chinese: [README.zh-CN.md](README.zh-CN.md)
- English: [README.en.md](README.en.md)

This repository builds a Docker image for `sing-box` with:

- `HY2` inbound
- `VLESS` inbound
- `MIXED` (HTTP+SOCKS5) local proxy inbound on port `1080` by default — traffic exits through WARP
- Cloudflare WARP outbound
- Optional automatic TLS via Cloudflare DNS API
- GitHub Actions multi-arch image build

If you want to reuse an existing WARP account, place `wgcf-account.toml` at `./data/wgcf-account.toml` before first start. Avoid putting real WARP credentials under `config/` or baking them into the image.
