# singbox-warp-docker

一个基于 Docker 的 `sing-box` 镜像模板，默认包含：

- `HY2` 入站
- `VLESS` 入站
- Cloudflare WARP 出站
- 可选自动 TLS（Cloudflare DNS API）
- GitHub Actions 多架构构建

## 快速开始

1. 复制 `.env.example` 为 `.env`
2. 按下面的“必填 / 可选 / 自动生成”填写配置
3. 运行：

```bash
docker compose up -d --build
```

4. 查看日志和节点链接：

```bash
docker compose logs -f
```

## 必填项

以下内容必须由你自己填写，否则容器无法正常对外提供服务：

- `.env` 中的 `TLS_DOMAIN`

启动脚本会自动把 `TLS_DOMAIN` 注入到两个入站的 `tls.server_name`，因此通常不需要再手改模板里的域名。

自动 TLS 模式还必须填写：

- `.env` `AUTO_TLS=true`
- `.env` `CF_Token=...`

这里的 `CF_Token` 只用于 Cloudflare DNS API 自动签发证书，不用于 WARP 注册。

手动证书模式还必须准备：

- `./certs/fullchain.pem`
- `./certs/privkey.pem`

如需复用现有 WARP 账号文件：

- 请在首次启动前把账号文件放到 `./data/wgcf-account.toml`
- 不要把真实 WARP 账号文件打进镜像，也不要提交进仓库

## 可选项

这些内容按需修改，不改也能启动：

- `.env` `HY2_PORT`，默认 `32443`
- `.env` `VLESS_PORT`，默认 `38443`
- `.env` `AUTH_UUID`，统一设置 `hy2 password` 和 `vless uuid`
- `.env` `HY2_PASSWORD`，单独覆盖 `hy2 password`
- `.env` `VLESS_UUID`，单独覆盖 `vless uuid`
- `.env` `ACME_EMAIL`
- `.env` `TLS_CERT_PATH`，默认 `/etc/sing-box/certs/fullchain.pem`
- `.env` `TLS_KEY_PATH`，默认 `/etc/sing-box/certs/privkey.pem`
- `.env` `TLS_ISSUE_RETRIES`，默认 `3`
- `.env` `TLS_RENEW_INTERVAL`，默认 `43200`
- `.env` `WARP_LICENSE_KEY`，可选，用于绑定 WARP+ 许可证
- `./data/wgcf-account.toml`，如果你已有 WARP 账户文件，可直接复用

## 自动生成或不要手改

下面这些值由启动脚本自动生成或自动替换，一般不要手动改：

- `config/sing-box.template.json` 中所有 `__WARP_*__`
- `config/sing-box.template.json` 中的 `__HY2_PORT__`
- `config/sing-box.template.json` 中的 `__VLESS_PORT__`
- `config/sing-box.template.json` 中的 `__HY2_PASSWORD__`
- `config/sing-box.template.json` 中的 `__VLESS_UUID__`
- `config/sing-box.template.json` 中的 `__TLS_DOMAIN__`
- `config/sing-box.template.json` 中的 `__TLS_CERT_PATH__`
- `config/sing-box.template.json` 中的 `__TLS_KEY_PATH__`

默认行为：

- 如果没有填写 `AUTH_UUID` / `HY2_PASSWORD` / `VLESS_UUID`，启动时会自动生成一个 UUID
- 默认自动生成的 UUID 会同时用于 `hy2 password` 和 `vless uuid`
- 如果没有提供 `./data/wgcf-account.toml`，容器首次启动会自动注册 WARP
- 如果填写了 `WARP_LICENSE_KEY`，启动时会自动尝试更新到对应的 WARP+ 许可证并重建 profile

## 自动 TLS 前置条件

- `TLS_DOMAIN` 必须已在 Cloudflare 托管，且 DNS 记录正确
- `CF_Token` 需要 Zone DNS 编辑权限
- 首次签发失败时，查看日志中的 `[tls]` 段落

## WARP 凭据说明

- 普通 WARP：不需要额外 token，容器首次启动时会自动注册
- WARP+：可选填写 `.env` 中的 `WARP_LICENSE_KEY`
- `./data/wgcf-account.toml` 以及 `./data` 目录其余内容用于持久化 WARP 账户与 profile
- `CF_Token` 不是 WARP token，它只服务于自动 TLS

## 持久化目录

- `./data`：保存 WARP 注册信息和生成的 profile
- `./acme`：保存 ACME 账户和续期状态
- `./certs`：保存 TLS 证书

凭据放置建议：

- `wgcf-account.toml` 应放在已被 git 忽略的 `./data` 目录下
- 不要把真实 WARP 凭据放进 `config/` 目录

## 运行安全

- `docker-compose.yml` 已添加基础资源限制：`mem_limit=512m`、`pids_limit=256`
- 已添加健康检查，检查 `sing-box` 主进程
- `.env` 已加入 `.gitignore`
- 容器主服务是 `sing-box`，证书续期由轻量 shell 循环托管，并已添加信号转发与优雅停机

## 配置模板说明

使用文件：`config/sing-box.template.json`

这是一份模板，不是最终运行文件。启动时脚本会自动注入：

- 端口
- `hy2 password`
- `vless uuid`
- `tls.server_name`
- 证书路径
- WARP 出站参数

你主要需要关注：

- 模板结构本身是否符合你的协议需求
- 是否需要额外自定义路由规则

模板示例：

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

## GitHub 构建

- Workflow 在 `push`、手动触发和定时任务时检查版本
- 只有 `sing-box` 或 `wgcf` 版本变化时才构建
- 镜像推送到 `ghcr.io/<owner>/singbox-warp-docker`

## 安全说明

- 不要把私钥、证书、`.env` 直接提交进仓库
- 使用自动 TLS 时，`CF_Token` 只给最小权限
