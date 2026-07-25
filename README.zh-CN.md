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

## 交互脚本

如果你要在 VPS 上一键部署、查看节点、查看状态，可以直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh -o deploy.sh && bash deploy.sh
```

脚本支持中文交互菜单，常用短命令是：

```bash
swd
```

首次安装使用自动 TLS。运行前请在 [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) 创建具有对应 Zone `DNS:Edit` 权限的 Token。脚本会隐藏 Token 输入，并将其保存到部署目录的 `.env` 中。

## 必填项

以下内容必须由你自己填写，否则容器无法正常对外提供服务：

- 建议填写 `.env` 中的 `TLS_DOMAIN`，用于自动 TLS 和节点链接生成

启动脚本会自动把 `TLS_DOMAIN` 注入到两个入站的 `tls.server_name`，因此通常不需要再手改模板里的域名。

自动 TLS 模式还必须填写：

- `.env` `AUTO_TLS=true`
- `.env` `TLS_DOMAIN`
- `.env` `CF_Token=...`

这里的 `CF_Token` 只用于 Cloudflare DNS API 自动签发证书，不用于 WARP 注册。

手动证书模式还必须准备：

- `./certs/fullchain.pem`
- `./certs/privkey.pem`
- 如果文件缺失，容器会在启动前直接报错并退出

如需复用现有 WARP 账号文件：

- 请在首次启动前把账号文件放到 `./data/wgcf-account.toml`
- 不要把真实 WARP 账号文件打进镜像，也不要提交进仓库

## 可选项

这些内容按需修改，不改也能启动：

- `.env` `HY2_PORT`，默认 `32443`
- `.env` `VLESS_PORT`，默认 `38443`
- `.env` `MIXED_PORT`，默认 `1080`（**本地 HTTP+SOCKS5 代理入口**，详见下节）
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

## 本地代理入口（MIXED）

容器内 sing-box 启动一个 **`mixed` 类型入站**，Docker 默认只映射到宿主机 **`127.0.0.1:1080`**，同时支持：

- **SOCKS5 代理**：`socks5://127.0.0.1:1080`
- **HTTP CONNECT 代理**：`http://127.0.0.1:1080`

**所有流量都通过 WARP 出口出去**，最终出口 IP 是 Cloudflare 边缘节点，**不是**你服务器本身的 IP。

典型用途：

- **本机工具代理**：让宿主机上的 `curl`、`git`、`apt` 等通过 `127.0.0.1:1080` 走出 WARP 网络
  ```bash
  curl -x socks5://127.0.0.1:1080 https://api.ipify.org
  ```
- **SSH 转发**：需要远程临时使用时，通过 SSH 端口转发访问本机 `1080`

**端口修改**：在 `.env` 设 `MIXED_PORT=xxxx` 即可，容器端口和宿主机本地端口会同步变更。

> ⚠️ **安全提示**：`1080` 端口没有任何认证机制，默认只绑定 `127.0.0.1`。不要改成 `0.0.0.0` 暴露到公网或局域网。

## `.env` 示例

下面给两份可以直接参考的示例。

### 示例 1：手动证书模式

```env
# 必须改：HY2 端口
HY2_PORT=32443

# 必须改：VLESS 端口
VLESS_PORT=38443

# 可选：本地 HTTP+SOCKS5 代理端口（不影响 HY2/VLESS 节点使用）
MIXED_PORT=1080

# 建议改：固定认证值。不填则启动时自动生成
AUTH_UUID=53fbb4a6-b0a1-4b0b-ae60-0b844c76580e

# 可留空：如果填写，则覆盖 HY2 密码；不填则跟 AUTH_UUID 一致
HY2_PASSWORD=

# 可留空：如果填写，则覆盖 VLESS UUID；不填则跟 AUTH_UUID 一致
VLESS_UUID=

# 不建议改：镜像构建参数，除非你明确要固定旧版本
SINGBOX_VERSION=1.11.8
WGCF_VERSION=2.2.26

# 必须确认：手动证书模式这里应为 false
AUTO_TLS=false

# 建议改：用于节点链接生成，建议填写真实域名
TLS_DOMAIN=1100.ccwu.cc

# 一般不用改：证书在容器内的路径
TLS_CERT_PATH=/etc/sing-box/certs/fullchain.pem
TLS_KEY_PATH=/etc/sing-box/certs/privkey.pem

# 可留空：手动证书模式不需要
ACME_EMAIL=

# 一般不用改
TLS_ISSUE_RETRIES=3
TLS_RENEW_INTERVAL=43200

# 可留空：普通 WARP 不需要；如有 WARP+ 可填写
WARP_LICENSE_KEY=

# 手动证书模式不需要
CF_Token=
CF_Account_ID=
CF_Zone_ID=
```

手动证书模式还必须准备：

- `./certs/fullchain.pem`
- `./certs/privkey.pem`

### 示例 2：自动 TLS 模式

```env
# 必须改：HY2 端口
HY2_PORT=32443

# 必须改：VLESS 端口
VLESS_PORT=38443

# 可选：本地 HTTP+SOCKS5 代理端口（不影响 HY2/VLESS 节点使用）
MIXED_PORT=1080

# 建议改：固定认证值。不填则启动时自动生成
AUTH_UUID=53fbb4a6-b0a1-4b0b-ae60-0b844c76580e

# 可留空
HY2_PASSWORD=
VLESS_UUID=

# 不建议改：镜像构建参数，除非你明确要固定旧版本
SINGBOX_VERSION=1.11.8
WGCF_VERSION=2.2.26

# 必须改：自动 TLS 模式这里应为 true
AUTO_TLS=true

# 必须改：真实域名，且必须已经解析到服务器 IP
TLS_DOMAIN=1100.ccwu.cc

# 一般不用改
TLS_CERT_PATH=/etc/sing-box/certs/fullchain.pem
TLS_KEY_PATH=/etc/sing-box/certs/privkey.pem

# 建议改：用于 ACME 账户注册邮箱
ACME_EMAIL=admin@1100.ccwu.cc

# 一般不用改
TLS_ISSUE_RETRIES=3
TLS_RENEW_INTERVAL=43200

# 可留空：普通 WARP 不需要；如有 WARP+ 可填写
WARP_LICENSE_KEY=

# 必须改：Cloudflare DNS API Token
CF_Token=your_cloudflare_dns_token

# 可留空：当前脚本默认不强制要求
CF_Account_ID=
CF_Zone_ID=
```

自动 TLS 模式注意：

- `TLS_DOMAIN` 必须已经解析到你的 VPS
- `CF_Token` 必须有对应 Zone 的 DNS 编辑权限
- 启动时会自动申请证书并写入 `./certs`

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
- `.env`：保存域名、端口、协议开关和认证信息，权限为 `600`
- `.deploy-state`：保存更新前的镜像 digest 和修改前的配置备份
- `/etc/singbox-warp/active-instance`：记录最后一次成功安装的部署目录，后续运行 `swd` 会自动使用该目录

重启或重新创建容器时，入口脚本会使用以上数据重新生成 sing-box 运行配置，因此 WARP 账号、证书和节点认证信息不会因容器重启而丢失。删除部署目录或这些持久化文件后无法自动恢复。

## 脚本化工业部署

仓库根目录提供 `deploy.sh`，用于多 VPS 的统一部署。

一键引导（全新 VPS 推荐）：

```bash
curl -fsSL https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh | bash
```

安装快捷命令 `swd`（后续直接输入 `swd` 唤醒脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh -o /usr/local/bin/swd && chmod +x /usr/local/bin/swd
```

说明：

- 脚本只提供交互模式（执行后逐项提示输入）
- 菜单提供首次安装、更新镜像、修改配置、查看节点、查看状态、诊断检查、查看日志、重启服务和回滚镜像
- 首次安装会先提示填写 `CF_Token`，再选择域名方式、协议和端口；镜像、认证值等低频参数位于高级选项
- 更新镜像不会覆盖 `.env`；修改配置会先读取现有值，允许隐藏输入新 `CF_Token`，并在写入前显示不含敏感信息的摘要
- 诊断检查是只读操作，会检查 Compose、容器健康、域名解析、Cloudflare Token、证书有效期和 WARP 出口
- “查看节点”只读取运行配置；容器常规日志不会输出完整节点链接或认证信息
- 更新后的容器未通过健康检查时，脚本会自动恢复更新前记录的镜像 digest
- 修改配置前会备份 `.env` 和 Compose；新配置启动失败时自动恢复旧配置
- 回滚镜像仅恢复更新前记录的容器镜像，不回滚证书或 WARP 数据
- 自动生成 `docker-compose.yml` 与 `.env`
- 自动拉取镜像并启动容器，最后执行健康检查
- 自动生成的 Compose 已限制 Docker 日志轮转：单文件 `10m`，保留 `3` 个文件，避免长期运行撑满磁盘

使用方式：

```bash
chmod +x ./deploy.sh
./deploy.sh
```

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

- HY2 端口 / 密码
- VLESS 端口 / UUID
- TLS 证书路径与域名
- WARP 出站参数
- `MIXED` 入站端口

模板里 3 个 inbound 的关系：

| 类型 | 用途 | 客户端 |
|---|---|---|
| `hysteria2` | 外部节点出站 | HY2 客户端（自用或分享） |
| `vless` | 外部节点出站 | v2rayN/Nekoray 等（自用或分享） |
| `mixed` | **本地 HTTP+SOCKS5 代理** | 宿主机工具 |

`mixed` 不需要密码/TLS；容器内监听 `0.0.0.0:1080`，但 Docker 只映射到宿主机 `127.0.0.1:1080`，流量立刻被 WARP 出口接管。

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

## GitHub 构建

- Workflow 在 `push`、手动触发和定时任务时检查版本
- 只有 `sing-box` 或 `wgcf` 版本变化时才构建
- 镜像推送到 `ghcr.io/<owner>/singbox-warp-docker`

## 安全说明

- 不要把私钥、证书、`.env` 直接提交进仓库
- 使用自动 TLS 时，`CF_Token` 只给最小权限
