FROM alpine:3.20

ARG SINGBOX_VERSION=1.11.8
ARG WGCF_VERSION=2.2.26

RUN apk add --no-cache ca-certificates curl tar bash jq tzdata

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) sb_arch='amd64'; wgcf_arch='amd64' ;; \
      aarch64) sb_arch='arm64'; wgcf_arch='arm64' ;; \
      *) echo "Unsupported arch: $arch"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${sb_arch}.tar.gz" -o /tmp/sb.tgz; \
    tar -xzf /tmp/sb.tgz -C /tmp; \
    cp "/tmp/sing-box-${SINGBOX_VERSION}-linux-${sb_arch}/sing-box" /usr/local/bin/sing-box; \
    chmod +x /usr/local/bin/sing-box; \
    curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wgcf_arch}" -o /usr/local/bin/wgcf; \
    chmod +x /usr/local/bin/wgcf; \
    rm -rf /tmp/*

WORKDIR /app

COPY entrypoint.sh /entrypoint.sh
COPY config/sing-box.template.json /etc/sing-box/template.json
COPY config/wgcf-account.toml /etc/wgcf/account.toml

RUN chmod +x /entrypoint.sh

VOLUME ["/var/lib/wgcf", "/etc/sing-box/certs"]

EXPOSE 8443/tcp 8443/udp

ENTRYPOINT ["/entrypoint.sh"]
