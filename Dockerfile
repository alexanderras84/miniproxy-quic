FROM alpine:3.20
ARG TARGETPLATFORM
ARG SINGBOX_VERSION=1.12.0-beta.33

# Environment variables
ENV ALLOWED_CLIENTS=127.0.0.1
ENV ALLOWED_CLIENTS_FILE=
ENV DYNDNS_CRON_SCHEDULE="*/1 * * * *"

# Expose necessary ports
EXPOSE 80/tcp
EXPOSE 443/tcp
EXPOSE 443/udp

# Print target platform info
RUN echo "I'm building for $TARGETPLATFORM"

# Install required packages
RUN apk update && apk upgrade && \
    apk add --no-cache \
        jq tini curl bash gnupg procps ca-certificates openssl \
        dog lua5.4-filesystem ipcalc libcap \
        supercronic step-cli bind-tools \
        iptables ip6tables ipset iproute2 unzip && \
    rm -rf /var/cache/apk/*

# Install sing-box
RUN curl -fSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" \
    -o /tmp/sing-box.tar.gz && \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp && \
    install -m 755 /tmp/sing-box/sing-box /usr/local/bin/sing-box && \
    rm -rf /tmp/sing-box /tmp/sing-box.tar.gz

# Create non-root user and groups
RUN addgroup miniproxy && adduser -D -H -G miniproxy miniproxy

# Create config directories
RUN mkdir -p /etc/miniproxy/ /etc/sing-box/

# Copy config and scripts
COPY config.json /etc/sing-box/config.json
COPY entrypoint.sh /entrypoint.sh
COPY generateACL.sh /generateACL.sh
COPY dynDNSCron.sh /dynDNSCron.sh
COPY acl_firewall.sh /acl_firewall.sh
COPY transparent_routing.sh /transparent_routing.sh

# Set ownership and permissions
RUN chown -R miniproxy:miniproxy /etc/sing-box/ /etc/miniproxy/ && \
    chown miniproxy:miniproxy /entrypoint.sh /generateACL.sh /dynDNSCron.sh /acl_firewall.sh /transparent_routing.sh && \
    chmod +x /entrypoint.sh /generateACL.sh /dynDNSCron.sh /acl_firewall.sh /transparent_routing.sh

# Entrypoint
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]