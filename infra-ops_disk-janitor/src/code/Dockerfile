FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    docker-cli \
    coreutils \
    curl \
    tzdata

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]