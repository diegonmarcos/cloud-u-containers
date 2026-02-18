# Matomo Hybrid Container
# Lightweight receiver always-on (~30-50MB), full Matomo stack on-demand
#
# Stage 1: Extract Matomo files from official image
# Stage 2: Build runtime with all services

# ─── Stage 1: Matomo source ─────────────────────────────────────────────────
FROM matomo:fpm-alpine AS matomo-source

# ─── Stage 2: Runtime ───────────────────────────────────────────────────────
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    php8.2-fpm \
    php8.2-mysql \
    php8.2-xml \
    php8.2-gd \
    php8.2-mbstring \
    php8.2-curl \
    php8.2-cli \
    php8.2-intl \
    php8.2-bcmath \
    php8.2-gmp \
    php8.2-ldap \
    php8.2-zip \
    mariadb-server \
    supervisor \
    curl \
    ca-certificates \
    jq \
    procps \
    sed \
    libmaxminddb0 \
    && rm -rf /var/lib/apt/lists/*

# Build and install maxminddb PHP extension
RUN apt-get update && apt-get install -y --no-install-recommends \
    php8.2-dev libmaxminddb-dev git make gcc \
    && git clone --depth 1 https://github.com/maxmind/MaxMind-DB-Reader-php.git /tmp/maxminddb \
    && cd /tmp/maxminddb/ext \
    && phpize \
    && ./configure \
    && make \
    && make install \
    && echo "extension=maxminddb.so" > /etc/php/8.2/mods-available/maxminddb.ini \
    && phpenmod maxminddb \
    && apt-get purge -y php8.2-dev libmaxminddb-dev git make \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /tmp/maxminddb

# Create required directories
RUN mkdir -p \
    /var/www/html \
    /var/www/receiver \
    /inbox \
    /var/log/supervisor \
    /var/log/nginx \
    /var/log/matomo-nginx \
    /run/php \
    /run/mysqld \
    /var/lib/mysql \
    /scripts \
    && chown mysql:mysql /run/mysqld /var/lib/mysql \
    && chown www-data:www-data /var/www/html /var/www/receiver /inbox

# Copy Matomo files from official image (only used for first-time init,
# existing volume data takes precedence)
COPY --from=matomo-source /usr/src/matomo /usr/src/matomo
COPY --from=matomo-source /entrypoint.sh /matomo-entrypoint.sh
RUN chmod +x /matomo-entrypoint.sh

# Copy configuration files
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/receiver-nginx.conf /etc/nginx/sites-available/receiver.conf
COPY config/matomo-nginx.conf /etc/nginx/matomo-nginx.conf
COPY config/receiver-fpm.conf /etc/php/8.2/fpm/receiver-fpm.conf
COPY config/matomo-fpm.conf /etc/php/8.2/fpm/matomo-fpm.conf
COPY config/mariadb.cnf /etc/mysql/mariadb.conf.d/99-matomo.cnf

# Remove default nginx/php-fpm configs, set up receiver as main nginx site
RUN rm -f /etc/nginx/sites-enabled/default \
    && rm -rf /etc/php/8.2/fpm/pool.d \
    && ln -sf /etc/nginx/sites-available/receiver.conf /etc/nginx/sites-enabled/receiver.conf

# Copy receiver PHP script
COPY receiver/receive.php /var/www/receiver/receive.php
RUN chown -R www-data:www-data /var/www/receiver

# Copy scripts
COPY scripts/entrypoint.sh /scripts/entrypoint.sh
COPY scripts/matomo-wake.sh /scripts/matomo-wake.sh
COPY scripts/matomo-sleep.sh /scripts/matomo-sleep.sh
COPY scripts/import-inbox.sh /scripts/import-inbox.sh
RUN chmod +x /scripts/*.sh

EXPOSE 8080

VOLUME ["/var/www/html", "/var/lib/mysql", "/inbox"]

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
