FROM alpine:3.20

ARG TARGETPLATFORM

# Environment variables
ENV ALLOWED_CLIENTS=127.0.0.1
ENV ALLOWED_CLIENTS_FILE=
ENV DYNDNS_CRON_SCHEDULE="*/1 * * * *"

# Expose required ports (optional with --network host)
EXPOSE 80/tcp
EXPOSE 443/tcp
EXPOSE 443/udp

# Debug build platform
RUN echo "Building for $TARGETPLATFORM"

# Install all required packages
RUN apk update && apk upgrade && \
    apk add --no-cache \
        bash curl git jq tini \
        gnupg procps ca-certificates openssl \
        dog lua5.4-filesystem ipcalc libcap \
        supercronic step-cli bind-tools \
        iptables ip6tables ipset iproute2 unzip \
        go gcc g++ libc-dev make && \
    rm -rf /var/cache/apk/*

# Build sing-box from the dev branch
RUN git clone --branch dev --depth 1 https://github.com/SagerNet/sing-box.git /src/sing-box && \
    cd /src/sing-box && \
    go build -o /usr/local/bin/sing-box ./cmd/sing-box && \
    strip /usr/local/bin/sing-box && \
    rm -rf /src/sing-box

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

# Permissions
RUN chown -R miniproxy:miniproxy /etc/sing-box/ /etc/miniproxy/ && \
    chown miniproxy:miniproxy \
      /entrypoint.sh /generateACL.sh /dynDNSCron.sh /acl_firewall.sh /transparent_routing.sh && \
    chmod +x \
      /entrypoint.sh /generateACL.sh /dynDNSCron.sh /acl_firewall.sh /transparent_routing.sh

# Entrypoint
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]