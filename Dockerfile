FROM alpine:3.20
ARG TARGETPLATFORM

# Environment variables
ENV ALLOWED_CLIENTS=127.0.0.1
ENV ALLOWED_CLIENTS_FILE=
ENV DYNDNS_CRON_SCHEDULE="*/1 * * * *"

# Expose ports (adjust if needed)
EXPOSE 443/tcp
EXPOSE 443/udp

# Show target platform at build time
RUN echo "I'm building for $TARGETPLATFORM"

# Add testing repo for sing-box
RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

# Install packages
RUN apk update && apk upgrade && \
    apk add --no-cache \
        bash curl jq tini gnupg procps ca-certificates openssl \
        dog lua5.4-filesystem ipcalc libcap iptables ipset sudo \
        supercronic step-cli bind-tools \
        sing-box@testing && \
    rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup miniproxy && adduser -D -H -G miniproxy miniproxy

# Give miniproxy user permission to run iptables via sudo
RUN echo "miniproxy ALL=(ALL) NOPASSWD: /sbin/iptables, /sbin/ipset" >> /etc/sudoers

# Create config and working directories
RUN mkdir -p /etc/miniproxy/ /etc/sing-box/

# Copy project scripts
COPY entrypoint.sh /entrypoint.sh
COPY generateACL.sh /generateACL.sh
COPY dynDNSCron.sh /dynDNSCron.sh
COPY acl_firewall.sh /acl_firewall.sh

# Set permissions
RUN chown -R miniproxy:miniproxy /etc/sing-box/ /etc/miniproxy/ && \
    chmod +x /entrypoint.sh /generateACL.sh /dynDNSCron.sh /acl_firewall.sh

# Use non-root user
USER miniproxy

# Entrypoint
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
