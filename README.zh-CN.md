# singbox-warp-docker

一个基于 Docker 的 `sing-box` 镜像模板，默认包含：

- `HY2` 入站
- `VLESS` 入站
- 可选 `AnyTLS` 入站
- 可选 `Shadowsocks 2022` 入站
- Cloudflare WARP 出站
- 可选自动 TLS（Cloudflare DNS API）
- GitHub Actions 多架构构建

## 快速开始

1. 复制 `.env.example` 为 `.env`
2. 按下面的“必填 / 可选 / 自动生成”填写配置
3. 运行：

```bash
docker compose up -d
```

4. 查看日志和节点链接：

```bash
docker compose logs -f
```

上面的命令使用已发布镜像。若要从源码构建，版本参数留空会自动获取最新发布版；也可以显式传入版本后，将 `docker-compose.yml` 中的 `image` 改为该镜像：

```bash
docker build --build-arg SINGBOX_VERSION= --build-arg WGCF_VERSION= -t singbox-warp-docker:local .
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

- `.env` 中的 `TLS_DOMAIN` 必须填写，用于 TLS 和节点链接生成

启动脚本会自动把 `TLS_DOMAIN` 注入到启用的 TLS 入站（HY2、VLESS、AnyTLS）的 `tls.server_name`，因此通常不需要再手改模板里的域名。

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
- `.env` `HY2_PORT_HOPPING`，默认 `false`；启用后由一键脚本映射 HY2 UDP 跳跃端口
- `.env` `HY2_HOP_PORTS`，留空时由一键脚本随机选择最多 50 个连续空闲端口；也可手动指定不超过 50 个端口的范围，但不能与现有协议端口重叠

端口跳跃目前由 `deploy.sh` 生成逐端口 Docker UDP 映射；直接使用仓库根目录的静态 `docker-compose.yml` 时不会根据范围自动生成映射，避免 Compose 配置被隐式改写。
- `.env` `VLESS_PORT`，默认 `38443`
- `.env` `ANYTLS_PORT`，默认 `4443`；启用 `ENABLE_ANYTLS=true` 后开放
- `.env` `SS_PORT`，默认 `48443`；启用 `ENABLE_SS=true` 后开放
- `.env` `MIXED_PORT`，默认 `1080`（**本地 HTTP+SOCKS5 代理入口**，详见下节）
- `.env` `ENABLE_HY2`，默认 `true`
- `.env` `ENABLE_VLESS`，默认 `true`
- `.env` `ENABLE_ANYTLS`，默认 `false`
- `.env` `ENABLE_SS`，默认 `false`
- `.env` `ENABLE_TUIC`，默认 `false`；TUIC v5（UDP），使用与 HY2 相同的证书
- `.env` `TUIC_PORT`，默认 `36443`（UDP）
- `.env` `TUIC_PASSWORD`，可选；留空时使用 `AUTH_UUID`（TUIC 的 uuid 同 `VLESS_UUID`）
- `.env` `ENABLE_REALITY`，默认 `false`；VLESS-Reality，不使用证书，借用伪装站点的 TLS 握手
- `.env` `REALITY_PORT`，默认 `443`；宿主机 443 已被 Web 服务占用时请改端口
- `.env` `REALITY_SNI`，默认 `www.microsoft.com`；伪装站点，需支持 TLS 1.3，建议选与 VPS 同地区、访问稳定的大站
- `.env` `REALITY_SHORT_ID`，可选；留空时自动生成。Reality 密钥对首次启动自动生成，保存在 `./data/credentials.env`
- `.env` `WARP_SCOPE`，默认 `all`；`all` 全部流量走 WARP，`split` 只有下面列出的站点走 WARP，其余直连（WARP 故障时只影响这些站点）
- `.env` `WARP_SPLIT_GEOSITE`，默认 `openai,anthropic,google-gemini,netflix,disney`；[sing-geosite](https://github.com/SagerNet/sing-geosite/tree/rule-set) 里的名称（去掉 `geosite-` 前缀），启动时下载到 `./data/rulesets`，每天刷新，下载失败沿用旧文件
- `.env` `WARP_SPLIT_DOMAINS`，可选；额外走 WARP 的域名后缀，逗号分隔，例如 `ipinfo.io,example.com`
- `.env` `AUTH_UUID`，统一设置 `hy2 password` 和 `vless uuid`
- `.env` `HY2_PASSWORD`，单独覆盖 `hy2 password`
- `.env` `VLESS_UUID`，单独覆盖 `vless uuid`
- `.env` `ANYTLS_PASSWORD`，可选；留空时使用 `AUTH_UUID`
- `.env` `SS_PASSWORD`，可选；留空时由一键安装脚本生成 Shadowsocks 2022 密钥
- `.env` `ACME_EMAIL`
- `.env` `TLS_CERT_PATH`，默认 `/etc/sing-box/certs/fullchain.pem`
- `.env` `TLS_KEY_PATH`，默认 `/etc/sing-box/certs/privkey.pem`
- `.env` `TLS_ISSUE_RETRIES`，默认 `3`
- `.env` `TLS_RENEW_INTERVAL`，默认 `43200`
- `.env` `WARP_LICENSE_KEY`，可选，用于绑定 WARP+ 许可证
- `.env` `NODE_NAME`，可选；留空时由一键脚本按 IP/城市自动生成节点名前缀
- `.env` `WARP_MODE`，默认 `auto`；可选 `auto` / `usque` / `wireguard` / `direct`
- `.env` `WARP_AUTORECOVER`，默认 `true`；WARP 不可用时先走 direct，恢复后自动切回
- `.env` `WARP_PROBE_INTERVAL`，默认 `60`（秒），WARP 健康检查间隔；正在使用的出口连续 3 次探测失败（失败后每 10 秒复查）才切换，避免网络抖动导致所有连接被断开；走 direct 时按 60 秒起、每次翻倍、最长 15 分钟的间隔重试；usque 注册失败后 1 小时内不再重试
- `.env` `USQUE_HTTP2`，默认 `true`；usque 走 MASQUE over HTTP/2（TCP 443）
- `./data/wgcf-account.toml`，如果你已有 WARP 账户文件，可直接复用

## 本地代理入口（MIXED）

容器内 sing-box 启动一个 **`mixed` 类型入站**，Docker 默认只映射到宿主机 **`127.0.0.1:1080`**，同时支持：

- **SOCKS5 代理**：`socks5://127.0.0.1:1080`
- **HTTP CONNECT 代理**：`http://127.0.0.1:1080`

**WARP 可用时所有流量都通过 WARP 出口出去**，最终出口 IP 是 Cloudflare 边缘节点，**不是**你服务器本身的 IP。

WARP 不可用时（例如出站 UDP 被平台限制）会自动回退到 direct，保证节点本身仍可正常使用；恢复后按 `WARP_PROBE_INTERVAL` 自动切回。

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
- `config/sing-box.template.json` 中的 `__ANYTLS_PASSWORD__`
- `config/sing-box.template.json` 中的 `__SS_PASSWORD__`
- `config/sing-box.template.json` 中的 `__TLS_DOMAIN__`
- `config/sing-box.template.json` 中的 `__TLS_CERT_PATH__`
- `config/sing-box.template.json` 中的 `__TLS_KEY_PATH__`

默认行为：

- 如果没有填写 `AUTH_UUID` / `HY2_PASSWORD` / `VLESS_UUID`，启动时会自动生成一个 UUID
- 默认自动生成的 UUID 会同时用于 `hy2 password` 和 `vless uuid`
- 自动生成的 `AUTH_UUID` / `SS_PASSWORD` 会保存到 `./data/credentials.env`，容器重启后保持不变；删除该文件才会重新生成
- 启动日志会打印各协议的节点链接（`[node] hy2://...` 等）
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
- `./backups`：保存手动创建的完整部署备份
- `/etc/singbox-warp/active-instance`：记录最后一次成功安装的部署目录，后续运行 `swd` 会自动使用该目录

重启或重新创建容器时，入口脚本会使用以上数据重新生成 sing-box 运行配置，因此 WARP 账号、证书和节点认证信息不会因容器重启而丢失。删除部署目录或这些持久化文件后无法自动恢复。

## 脚本化工业部署

仓库根目录提供 `deploy.sh`，用于多 VPS 的统一部署。

一键引导（全新 VPS 推荐）：

```bash
curl -fsSL https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh -o deploy.sh && bash deploy.sh
```

安装快捷命令 `swd`（后续直接输入 `swd` 唤醒脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh -o /usr/local/bin/swd && chmod +x /usr/local/bin/swd
```

说明：

- 当前管理脚本版本：`2.3.0`；运行 `swd --version` 可查看线上版本
- 普通用户运行时会自动请求 `sudo` 权限并以 root 重新启动；`--help` 和 `--version` 不需要提权
- 脚本只提供交互模式（执行后逐项提示输入）
- 菜单提供安装、镜像/管理脚本更新、配置修改、节点二维码、状态总览、诊断、日志、重启、备份恢复、自动更新、回滚和卸载
- 首次安装会先提示填写 `CF_Token`，再选择域名方式、协议和端口；镜像、认证值等低频参数位于高级选项
- 更新镜像不会覆盖 `.env`；修改配置会先读取现有值，允许隐藏输入新 `CF_Token`，并在写入前显示不含敏感信息的摘要
- 诊断检查是只读操作，会检查 Compose、容器健康、域名解析、Cloudflare Token、证书有效期和 WARP 出口
- “查看节点”只读取运行配置；容器常规日志不会输出完整节点链接或认证信息
- 查看节点时会输出链接和终端二维码；二维码同样包含认证信息，不要截屏公开分享
- 更新后的容器未通过健康检查时，脚本会自动恢复更新前记录的镜像 digest
- 修改配置前会备份 `.env` 和 Compose；新配置启动失败时自动恢复旧配置
- 回滚镜像仅恢复更新前记录的容器镜像，不回滚证书或 WARP 数据
- 创建备份时会短暂停止容器，归档 `.env`、Compose、WARP、证书、ACME 和部署状态；恢复前会检查归档路径与链接类型
- 自动更新通过 systemd timer 每天检查一次，默认关闭；可在菜单中启用、禁用或查看状态
- 卸载支持保留数据和完全删除两种模式；完全删除前会在部署目录外创建最终备份，并要求输入 `DELETE`
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

## 版本化发布

- 推送 `vX.Y.Z` 标签（必须等于 `deploy.sh` 的 `SCRIPT_VERSION`）会构建镜像并打上 `X.Y.Z`、`X.Y` 和 `latest` 标签，同时发布 GitHub Release，附带 `deploy.sh` 和 `deploy.sh.sha256`
- 想固定版本：把 compose 里的 `image` 改成 `ghcr.io/caichengle666/singbox-warp-docker:X.Y.Z`
- 带版本号的镜像不会被自动清理；`latest` 仍按原方式每天跟随上游更新

## 配置模板说明

使用文件：`config/sing-box.template.json`（以该文件为准，这里只讲结构）。

这是一份模板，不是最终运行文件。启动时脚本会自动注入端口、密码/UUID、TLS 证书路径与域名、WARP WireGuard 参数和 `MIXED` 端口，并删除未启用的入站，渲染后先跑一遍 `sing-box check`。

- 入站：HY2、VLESS、AnyTLS、Shadowsocks 2022、TUIC v5、VLESS-Reality（`reality-in`）（按 `ENABLE_*` 保留），`mixed-in`（宿主机本地代理），以及仅容器内使用的 `warp-probe`（127.0.0.1:18080，用于探测 WARP）
- 出站：`warp`（WireGuard endpoint）、`usque`（MASQUE SOCKS，127.0.0.1:18081）、`direct`
- 路由规则：
  1. `warp-probe` 固定走 `warp`
  2. 目标是私有/内网地址（含 `169.254.169.254` 云元数据、容器回环）的连接直接拒绝，避免节点被用来访问服务器内网
  3. `WARP_SCOPE=all`：其余流量走 `route.final`，由启动脚本在 `usque` / `warp` / `direct` 之间切换
  4. `WARP_SCOPE=split`：额外加入 `sniff` 和分流规则（geosite 规则集 / 域名后缀），脚本切换的是这些规则的出口，`route.final` 固定为 `direct`

如需自定义规则，请加在第 2 条之后，并保持 `route.final` 由脚本管理。

## GitHub 构建

- Workflow 在 `push`、手动触发和每日定时任务时运行
- 每次都会用最新 `sing-box` 对渲染后的模板跑 `sing-box check`，不通过就不会构建和推送
- 构建镜像后先在 CI 里真实启动容器（不加任何额外 capability），用 sing-box 客户端逐个连接 HY2 / VLESS / AnyTLS / SS / Reality / TUIC 并访问外网，同时检查私网拦截和本地 MIXED 代理；全部通过才推送。本地可运行 `scripts/runtime-test.sh <镜像> <sing-box 客户端>`
- `push` 时只有代码/配置改动才构建；定时任务只有 `sing-box` 或 `wgcf` 出新版时才构建
- 镜像推送到 `ghcr.io/<owner>/singbox-warp-docker`

## 安全说明

- 不要把私钥、证书、`.env` 直接提交进仓库
- 使用自动 TLS 时，`CF_Token` 只给最小权限
- 当前管理脚本版本：`2.3.0`；运行 `swd --version` 可查看线上版本
