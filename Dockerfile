FROM alpine:3.20
ARG TARGETPLATFORM

ENV ALLOWED_CLIENTS=127.0.0.1
ENV ALLOWED_CLIENTS_FILE=

ENV DYNDNS_CRON_SCHEDULE="*/1 * * * *"

# HEALTHCHECKS
HEALTHCHECK --interval=30s --timeout=3s CMD (pgrep "nginx" > /dev/null) || exit 1

# Expose Ports
EXPOSE 8080/tcp
EXPOSE 8443/tcp

RUN echo "I'm building for $TARGETPLATFORM"

# Update Base
RUN apk update && apk upgrade

# Create Users
RUN addgroup miniproxy && adduser -D -H -G miniproxy miniproxy

# Install needed packages and clean up
RUN apk add --no-cache jq tini curl bash gnupg procps ca-certificates openssl dog lua5.4-filesystem ipcalc libcap nginx nginx-mod-stream supercronic step-cli bind-tools && \
    rm -f /etc/nginx/conf.d/*.conf && \
    rm -rf /var/cache/apk/*

# Setup Folder(s)
RUN mkdir -p /etc/miniproxy/

# Copy Files
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
COPY generateACL.sh /generateACL.sh
COPY dynDNSCron.sh /dynDNSCron.sh

RUN chown -R miniproxy:miniproxy /etc/nginx/ && \
    chown -R miniproxy:miniproxy /etc/miniproxy/ && \
    chown -R miniproxy:miniproxy /var/log/nginx/ && \
    chown -R miniproxy:miniproxy /var/lib/nginx/ && \
    chown -R miniproxy:miniproxy /run/nginx/ && \
    chmod +x /entrypoint.sh && \
    chmod +x /generateACL.sh && \
    chmod +x dynDNSCron.sh

USER miniproxy

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
