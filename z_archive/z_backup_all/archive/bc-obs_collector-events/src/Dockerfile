FROM alpine:3.19
RUN apk add --no-cache curl docker-cli
COPY collector.sh /usr/local/bin/collector
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/collector /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
