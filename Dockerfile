FROM alpine:3.20
ARG TARGETPLATFORM

# Environment variables
ENV ALLOWED_CLIENTS=127.0.0.1
ENV ALLOWED_CLIENTS_FILE=
ENV DYNDNS_CRON_SCHEDULE="*/1 * * * *"

# Expose ports (adjust if needed)
EXPOSE 443/tcp
EXPOSE 443/udp

# Print target platform and kernel info
RUN echo "Building for: ${TARGETPLATFORM:-unknown}" && uname -a

# Add testing repo for sing-box
RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

# Install packages (you can pin versions more strictly if needed)
RUN apk update && apk upgrade && \
    apk add --no-cache \
        jq tini curl bash gnupg procps ca-certificates openssl \
        dog lua5.4-filesystem ipcalc libcap \
        supercronic step-cli bind-tools \
        sing-box@testing=1.8.0-r0 && \
    rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup miniproxy && adduser -D -H -G miniproxy miniproxy

# Create config dirs
RUN mkdir -p /etc/miniproxy/ && mkdir -p /etc/sing-box/

# Copy project files
COPY entrypoint.sh /entrypoint.sh
COPY generateACL.sh /generateACL.sh
COPY dynDNSCron.sh /dynDNSCron.sh

# Permissions
RUN chown -R miniproxy:miniproxy /etc/sing-box/ /etc/miniproxy/ && \
    chmod +x /entrypoint.sh /generateACL.sh /dynDNSCron.sh

# Use non-root user
USER miniproxy

# Healthcheck (optional: replace URL with local admin interface or dummy check)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sSf http://127.0.0.1:443/health || exit 1

# Entrypoint & CMD
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
