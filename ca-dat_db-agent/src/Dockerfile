FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    sqlite \
    postgresql16-client \
    mariadb-client \
    redis \
    bup \
    openssh-client \
    curl \
    docker-cli \
    tzdata

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/log/db-agent"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
