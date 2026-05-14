FROM debian:trixie-slim

ARG SINGBOX_VERSION=1.11.8
ARG WGCF_VERSION=2.2.26

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar bash jq tzdata openssl socat \
    && rm -rf /var/lib/apt/lists/*

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
    curl -fsSL https://get.acme.sh | sh -s email=none@example.com --force; \
    rm -rf /tmp/*

WORKDIR /app

COPY entrypoint.sh /entrypoint.sh
COPY config/sing-box.template.json /etc/sing-box/template.json

RUN sed -i 's/\r$//' /entrypoint.sh \
    && chmod +x /entrypoint.sh

VOLUME ["/var/lib/wgcf", "/etc/sing-box/certs", "/var/lib/acme"]

EXPOSE 32443/tcp 32443/udp 38443/tcp

ENTRYPOINT ["/entrypoint.sh"]
