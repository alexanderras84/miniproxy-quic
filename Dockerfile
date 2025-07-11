FROM alpine:3.20
ARG TARGETPLATFORM

# Environment variables
ENV ALLOWED_CLIENTS=127.0.0.1
ENV ALLOWED_CLIENTS_FILE=
ENV DYNDNS_CRON_SCHEDULE="*/1 * * * *"

# Expose necessary ports
EXPOSE 443/tcp
EXPOSE 443/udp

# Print target platform info
RUN echo "I'm building for $TARGETPLATFORM"

# Add testing repo for sing-box
RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

# Install required packages
RUN apk update && apk upgrade && \
    apk add --no-cache \
        jq tini curl bash gnupg procps ca-certificates openssl \
        dog lua5.4-filesystem ipcalc libcap \
        supercronic step-cli bind-tools \
        sing-box@testing && \
    rm -rf /var/cache/apk/*

# Create non-root user and groups
RUN addgroup miniproxy && adduser -D -H -G miniproxy miniproxy

# Create config directories
RUN mkdir -p /etc/miniproxy/ /etc/sing-box/

# Copy static config and scripts
COPY config.json /etc/sing-box/config.json
COPY entrypoint.sh /entrypoint.sh
COPY generateACL.sh /generateACL.sh
COPY dynDNSCron.sh /dynDNSCron.sh

# Set ownership and execution permissions
RUN chown -R miniproxy:miniproxy /etc/sing-box/ /etc/miniproxy/ && \
    chmod +x /entrypoint.sh /generateACL.sh /dynDNSCron.sh

# Switch to non-root user
USER miniproxy

# Entrypoint and default command
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
