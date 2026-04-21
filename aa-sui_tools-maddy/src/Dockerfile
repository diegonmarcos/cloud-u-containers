FROM foxcpp/maddy:0.9

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Maddy Mail Server wrapped for GHCR"
LABEL cloud.diegonmarcos.from-image="foxcpp/maddy:0.9"
LABEL cloud.diegonmarcos.registry="ghcr.io/diegonmarcos"

# Python + delivery-time IMAP filter (replaces former maddy-sorter container).
# Wired into maddy.conf.tpl as `imap_filter { command /usr/local/bin/mail-filter }`.
RUN apk add --no-cache python3
COPY mail-filter.py /usr/local/bin/mail-filter
RUN chmod +x /usr/local/bin/mail-filter
