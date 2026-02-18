FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    curl \
    systemd \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

COPY collector.sh /collector.sh
RUN chmod +x /collector.sh

CMD ["/collector.sh"]
