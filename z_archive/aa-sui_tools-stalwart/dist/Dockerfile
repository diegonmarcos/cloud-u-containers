FROM stalwartlabs/mail-server:v0.11
COPY config.toml.tpl /opt/stalwart-mail/etc/config.toml.tpl
COPY init.sh /opt/stalwart-mail/init.sh
RUN apt-get update && apt-get install -y --no-install-recommends gettext-base curl && rm -rf /var/lib/apt/lists/*
COPY docker-compose.yml /opt/cloud-docs/docker-compose.yml
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.description="stalwart"
LABEL org.opencontainers.image.title="stalwart"
LABEL cloud.diegonmarcos.from-image="stalwartlabs/mail-server:v0.11"
LABEL cloud.diegonmarcos.registry="ghcr.io/diegonmarcos"
