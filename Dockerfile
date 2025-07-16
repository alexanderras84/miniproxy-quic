FROM alpine:3.20

ARG SINGBOX_VERSION=1.12.0-beta.33

EXPOSE 443/tcp
EXPOSE 443/udp

RUN apk update && apk upgrade && \
    apk add --no-cache \
        jq tini curl bash gnupg procps ca-certificates openssl \
        dog lua5.4-filesystem ipcalc libcap \
        supercronic step-cli bind-tools \
        iptables ip6tables ipset iproute2 unzip && \
    rm -rf /var/cache/apk/*

RUN curl -fSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" \
    -o /tmp/sing-box.tar.gz && \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp && \
    install -m 755 /tmp/sing-box*/sing-box /usr/local/bin/sing-box && \
    rm -rf /tmp/sing-box* /tmp/sing-box.tar.gz

RUN addgroup miniproxy && adduser -D -H -G miniproxy miniproxy

RUN mkdir -p /etc/sing-box/ /etc/miniproxy

COPY config.base.json /etc/sing-box/config.base.json
COPY generateacl.sh /generateacl.sh
COPY dyndnscron.sh /dyndnscron.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /generateacl.sh /dyndnscron.sh /entrypoint.sh
RUN chown -R miniproxy:miniproxy /etc/sing-box/

# Default allowed clients and DynDNS cron settings
ENV ALLOWED_CLIENTS="127.0.0.1"
ENV DYNDNS_CRON_ENABLED="false"
ENV DYNDNS_CRON_SCHEDULE="*/10 * * * *"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
