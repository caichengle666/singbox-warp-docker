#!/usr/bin/env bash
# End-to-end runtime test for a built image.
#
# Starts the container with every protocol enabled (manual TLS with a
# self-signed certificate, no extra capabilities), then connects to each
# inbound with a sing-box client and fetches a public page through it.
# Also checks that private addresses are rejected and that WARP_SCOPE=split
# rendered its rules.
#
# WARP availability depends on the network the test runs in, so a missing
# WARP egress is reported as a warning, not a failure.
#
# Usage: scripts/runtime-test.sh <image> [path-to-sing-box-client-binary]
set -euo pipefail

IMAGE="${1:?usage: runtime-test.sh <image> [sing-box]}"
SING_BOX="${2:-sing-box}"
NAME="swd-runtime-test"
DOMAIN="test.local"
TEST_URL="https://www.cloudflare.com/cdn-cgi/trace"
work="$(mktemp -d)"
client_pid=""

cleanup() {
  [ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true
  if [ "${KEEP_CONTAINER:-false}" != "true" ]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
  # The container writes data/ as root; remove it from inside a container
  # when the runner user cannot.
  if ! rm -rf "$work" 2>/dev/null; then
    docker run --rm -v "$work:/w" --entrypoint sh "$IMAGE" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
    rm -rf "$work" 2>/dev/null || true
  fi
  return 0
}
trap cleanup EXIT

# Annotations are the only part of a run visible without signing in, so
# failures are reported as one annotation carrying the container log tail.
annotate_log() {
  local log
  log="$(docker logs "$NAME" 2>&1 | tail -n 60 | sed 's/\x1b\[[0-9;]*m//g' || true)"
  log="${log//'%'/'%25'}"
  log="${log//$'\r'/}"
  log="${log//$'\n'/'%0A'}"
  echo "::error title=container log::${log}"
}

fail() {
  echo "::error title=runtime test::$*"
  annotate_log
  echo "----- container log -----"
  docker logs "$NAME" 2>&1 | tail -n 80 || true
  exit 1
}
trap 'fail "command failed at line $LINENO: $BASH_COMMAND"' ERR

mkdir -p "$work/certs" "$work/data"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$work/certs/privkey.pem" -out "$work/certs/fullchain.pem" -days 2 \
  -subj "/CN=${DOMAIN}" >/dev/null 2>&1
chmod 644 "$work/certs/"*.pem

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --init \
  --security-opt no-new-privileges:true \
  -v "$work/certs:/etc/sing-box/certs" \
  -v "$work/data:/var/lib/wgcf" \
  -p 127.0.0.1:32443:32443/udp \
  -p 127.0.0.1:38443:38443/tcp \
  -p 127.0.0.1:4443:4443/tcp \
  -p 127.0.0.1:48443:48443/tcp \
  -p 127.0.0.1:36443:36443/udp \
  -p 127.0.0.1:20443:20443/tcp \
  -p 127.0.0.1:21080:21080/tcp \
  -p 127.0.0.1:28080:28080/tcp \
  -e AUTO_TLS=false \
  -e TLS_DOMAIN="$DOMAIN" \
  -e ENABLE_HY2=true -e ENABLE_VLESS=true -e ENABLE_ANYTLS=true \
  -e ENABLE_SS=true -e ENABLE_TUIC=true -e ENABLE_REALITY=true \
  -e ENABLE_WS=true -e WS_PORT=28080 -e WS_HOST="$DOMAIN" \
  -e REALITY_PORT=20443 -e MIXED_PORT=21080 \
  -e WARP_SCOPE=split -e WARP_SPLIT_GEOSITE=openai -e WARP_SPLIT_DOMAINS=example.org \
  "$IMAGE" >/dev/null

echo "waiting for sing-box to start"
for _ in $(seq 1 90); do
  docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true || fail "container exited during startup"
  docker logs "$NAME" 2>&1 | grep -q 'sing-box started' && break
  sleep 2
done
docker logs "$NAME" 2>&1 | grep -q 'sing-box started' || fail "sing-box did not start within 180s"
# Give the startup WARP attempt time to finish before probing.
for _ in $(seq 1 30); do
  docker logs "$NAME" 2>&1 | grep -Eq '\[warp\] (using|no WARP egress)' && break
  sleep 2
done

creds="$(docker exec "$NAME" cat /var/lib/wgcf/credentials.env)"
cred() { printf '%s\n' "$creds" | sed -n "s/^$1=//p" | head -n1; }
uuid="$(cred AUTH_UUID)"
ss_password="$(cred SS_PASSWORD)"
reality_pub="$(cred REALITY_PUBLIC_KEY)"
reality_sid="$(cred REALITY_SHORT_ID)"
ws_path="$(cred WS_PATH)"
[ -n "$uuid" ] && [ -n "$ss_password" ] && [ -n "$reality_pub" ] && [ -n "$reality_sid" ] && [ -n "$ws_path" ] ||
  fail "credentials.env is missing generated values"

config="$(docker exec "$NAME" cat /etc/sing-box/config.json)"
jq -e '.route.rules | any(.action == "sniff")' <<<"$config" >/dev/null || fail "split mode: sniff rule missing"
jq -e '.route.rules | any(.domain_suffix == ["example.org"])' <<<"$config" >/dev/null || fail "split mode: domain rule missing"
jq -e '.route.final == "direct"' <<<"$config" >/dev/null || fail "split mode: route.final is not direct"

jq -n \
  --arg uuid "$uuid" --arg ss "$ss_password" --arg pub "$reality_pub" --arg sid "$reality_sid" --arg sni "$DOMAIN" --arg wsPath "$ws_path" '
  def tls: {"enabled": true, "server_name": $sni, "insecure": true};
  {
    "log": {"level": "warn"},
    "inbounds": [
      {"type": "mixed", "tag": "c-hy2", "listen": "127.0.0.1", "listen_port": 31001},
      {"type": "mixed", "tag": "c-vless", "listen": "127.0.0.1", "listen_port": 31002},
      {"type": "mixed", "tag": "c-anytls", "listen": "127.0.0.1", "listen_port": 31003},
      {"type": "mixed", "tag": "c-ss", "listen": "127.0.0.1", "listen_port": 31004},
      {"type": "mixed", "tag": "c-reality", "listen": "127.0.0.1", "listen_port": 31005},
      {"type": "mixed", "tag": "c-tuic", "listen": "127.0.0.1", "listen_port": 31006},
      {"type": "mixed", "tag": "c-ws", "listen": "127.0.0.1", "listen_port": 31007}
    ],
    "outbounds": [
      {"type": "hysteria2", "tag": "hy2", "server": "127.0.0.1", "server_port": 32443, "password": $uuid, "tls": tls},
      {"type": "vless", "tag": "vless", "server": "127.0.0.1", "server_port": 38443, "uuid": $uuid, "flow": "xtls-rprx-vision", "tls": tls},
      {"type": "anytls", "tag": "anytls", "server": "127.0.0.1", "server_port": 4443, "password": $uuid, "tls": tls},
      {"type": "shadowsocks", "tag": "ss", "server": "127.0.0.1", "server_port": 48443, "method": "2022-blake3-aes-256-gcm", "password": $ss, "network": "tcp"},
      {"type": "vless", "tag": "reality", "server": "127.0.0.1", "server_port": 20443, "uuid": $uuid, "flow": "xtls-rprx-vision",
       "tls": {"enabled": true, "server_name": "www.microsoft.com", "utls": {"enabled": true, "fingerprint": "chrome"},
               "reality": {"enabled": true, "public_key": $pub, "short_id": $sid}}},
      {"type": "tuic", "tag": "tuic", "server": "127.0.0.1", "server_port": 36443, "uuid": $uuid, "password": $uuid,
       "congestion_control": "bbr", "tls": (tls + {"alpn": ["h3"]})},
      {"type": "vless", "tag": "ws", "server": "127.0.0.1", "server_port": 28080, "uuid": $uuid,
       "transport": {"type": "ws", "path": $wsPath, "headers": {"Host": $sni},
                     "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"}}
    ],
    "route": {"rules": [
      {"inbound": ["c-hy2"], "outbound": "hy2"},
      {"inbound": ["c-vless"], "outbound": "vless"},
      {"inbound": ["c-anytls"], "outbound": "anytls"},
      {"inbound": ["c-ss"], "outbound": "ss"},
      {"inbound": ["c-reality"], "outbound": "reality"},
      {"inbound": ["c-tuic"], "outbound": "tuic"},
      {"inbound": ["c-ws"], "outbound": "ws"}
    ]}
  }' > "$work/client.json"

"$SING_BOX" run -c "$work/client.json" > "$work/client.log" 2>&1 &
client_pid="$!"
sleep 2

failed=0
for entry in 31001:hy2 31002:vless 31003:anytls 31004:ss 31005:reality 31006:tuic 31007:ws; do
  port="${entry%%:*}" proto="${entry#*:}" ok=false
  for _ in 1 2 3; do
    if curl -fsS -o /dev/null --max-time 15 -x "socks5h://127.0.0.1:${port}" "$TEST_URL"; then
      ok=true
      break
    fi
    sleep 2
  done
  if [ "$ok" = "true" ]; then
    echo "ok   $proto"
  else
    echo "FAIL $proto"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || { cat "$work/client.log" >&2; fail "one or more protocols failed"; }

# Private destinations must be rejected (here: the container's own mixed port).
if curl -fsS -o /dev/null --max-time 5 -x socks5h://127.0.0.1:31002 http://127.0.0.1:21080/ 2>/dev/null; then
  fail "private address was reachable through the node"
fi
echo "ok   private address rejected"

# Host-local mixed proxy.
curl -fsS -o /dev/null --max-time 15 -x socks5h://127.0.0.1:21080 "$TEST_URL" || fail "mixed proxy failed"
echo "ok   mixed proxy"

if docker logs "$NAME" 2>&1 | grep -q '\[warp\] using'; then
  echo "ok   WARP egress: $(docker logs "$NAME" 2>&1 | grep '\[warp\] using' | tail -n1)"
else
  echo "::warning::no WARP egress came up in this environment (runs on direct); protocol checks still passed"
fi

# Tunnel mode: only the WebSocket inbound, no certificate mounted. AUTO_TLS is
# set without a token to prove it is skipped when nothing needs a cert.
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --init \
  --security-opt no-new-privileges:true \
  -v "$work/data:/var/lib/wgcf" \
  -p 127.0.0.1:28080:28080/tcp \
  -e AUTO_TLS=true \
  -e ENABLE_HY2=false -e ENABLE_VLESS=false \
  -e ENABLE_WS=true -e WS_PORT=28080 -e WS_HOST=tunnel.example.com \
  -e WARP_MODE=direct \
  "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true || fail "tunnel mode: container exited during startup"
  docker logs "$NAME" 2>&1 | grep -q 'sing-box started' && break
  sleep 2
done
docker logs "$NAME" 2>&1 | grep -q 'sing-box started' || fail "tunnel mode: sing-box did not start"
config="$(docker exec "$NAME" cat /etc/sing-box/config.json)"
jq -e '[.inbounds[] | select(.type != "mixed")] | length == 1 and .[0].transport.type == "ws"' <<<"$config" >/dev/null ||
  fail "tunnel mode: expected only the WebSocket inbound"
docker logs "$NAME" 2>&1 | grep -q 'type=ws&path=' || fail "tunnel mode: client link not printed"
ok=false
for _ in 1 2 3; do
  if curl -fsS -o /dev/null --max-time 15 -x socks5h://127.0.0.1:31007 "$TEST_URL"; then ok=true; break; fi
  sleep 2
done
[ "$ok" = "true" ] || fail "tunnel mode: WebSocket inbound failed"
# Anything other than the WebSocket path must not be served.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:28080/ || true)"
[ "$code" != "101" ] && [ "$code" != "200" ] || fail "tunnel mode: root path answered with $code"
echo "ok   tunnel mode (ws only, no certificate)"

echo "runtime test passed"
