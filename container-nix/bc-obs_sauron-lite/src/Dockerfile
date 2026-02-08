# Sauron-Lite: Hybrid watcher + YARA scanner
# Image: ~15MB | RAM: 2-5MB idle, 20-30MB during scan

FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    inotify-tools \
    yara \
    && rm -rf /var/cache/apk/*

COPY watcher.sh /usr/local/bin/watcher.sh
COPY scanner.sh /usr/local/bin/scanner.sh
RUN chmod +x /usr/local/bin/watcher.sh /usr/local/bin/scanner.sh

RUN mkdir -p /var/log/sauron /var/spool/sauron /etc/sauron/yara-rules /watch

# Cron job: run scanner every 5 minutes
RUN echo "*/5 * * * * /usr/local/bin/scanner.sh >> /var/log/sauron/scanner.log 2>&1" > /etc/crontabs/root

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
