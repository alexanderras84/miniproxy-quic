FROM alpine:3.20

# -------------------------------------------------
# Sing-Box stable version (latest stable as of now)
# -------------------------------------------------
ARG SINGBOX_VERSION=1.12.22

ENV ALLOWED_CLIENTS="127.0.0.1"
ENV DYNDNS_CRON_ENABLED="false"
ENV DYNDNS_CRON_SCHEDULE="*/1 * * * *"

EXPOSE 80/tcp
EXPOSE 443/tcp
EXPOSE 443/udp

# -------------------------------------------------
# Install required packages
# -------------------------------------------------
RUN apk update && apk upgrade && \
    apk add --no-cache \
        jq tini curl bash gnupg procps ca-certificates openssl \
        dog lua5.4-filesystem ipcalc libcap \
        supercronic step-cli bind-tools nano \
        iptables ip6tables ipset iproute2 unzip && \
    rm -rf /var/cache/apk/*

# -------------------------------------------------
# Download & install sing-box stable release
# -------------------------------------------------
RUN curl -fSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" \
    -o /tmp/sing-box.tar.gz && \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp && \
    install -m 755 /tmp/sing-box*/sing-box /usr/local/bin/sing-box && \
    rm -rf /tmp/sing-box* /tmp/sing-box.tar.gz

# -------------------------------------------------
# Create runtime user & directories
# -------------------------------------------------
RUN addgroup miniproxy && adduser -D -H -G miniproxy miniproxy
RUN mkdir -p /etc/sing-box /etc/miniproxy

# -------------------------------------------------
# Copy config & scripts
# -------------------------------------------------
COPY config.json /etc/sing-box/config.json
#COPY generateacl.sh /generateacl.sh
#COPY dyndnscron.sh /dyndnscron.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /generateacl.sh /dyndnscron.sh /entrypoint.sh
RUN chown -R miniproxy:miniproxy /etc/sing-box

# -------------------------------------------------
# Entrypoint
# -------------------------------------------------
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
