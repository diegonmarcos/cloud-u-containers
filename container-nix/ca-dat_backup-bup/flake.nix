{
  description = "Bup - Git-based incremental backup for databases";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      container_name = "backup-bup";
      timezone = "Europe/Madrid";
      backup_dir = "/backup/databases";

      # Retention
      keep_days = 30;

      # Schedule (cron format)
      schedule = "0 3 * * *";  # 3 AM daily
    };

    # Dockerfile for bup with database dump tools
    dockerfile = pkgs.writeText "Dockerfile" ''
      FROM debian:bookworm-slim

      RUN apt-get update && apt-get install -y --no-install-recommends \
          bup \
          sqlite3 \
          mariadb-client \
          postgresql-client \
          cron \
          bash \
          curl \
          gzip \
          && rm -rf /var/lib/apt/lists/*

      WORKDIR /app

      COPY backup.sh /app/backup.sh
      COPY entrypoint.sh /app/entrypoint.sh
      RUN chmod +x /app/*.sh

      ENTRYPOINT ["/app/entrypoint.sh"]
    '';

    # Main backup script
    backupSh = pkgs.writeText "backup.sh" ''
      #!/bin/bash
      set -e

      BACKUP_DIR="''${BACKUP_DIR:-/backup}"
      BUP_DIR="''${BUP_DIR:-$BACKUP_DIR/bup}"
      DUMP_DIR="''${DUMP_DIR:-$BACKUP_DIR/dumps}"
      KEEP_DAYS="''${KEEP_DAYS:-30}"
      TIMESTAMP=$(date +%Y%m%d_%H%M%S)

      log() {
          echo "[$(date -Iseconds)] $1"
      }

      mkdir -p "$BUP_DIR" "$DUMP_DIR"

      # Initialize bup repo if needed
      if [ ! -d "$BUP_DIR/objects" ]; then
          log "Initializing bup repository..."
          BUP_DIR="$BUP_DIR" bup init
      fi

      export BUP_DIR

      # Dump SQLite databases
      if [ -n "$SQLITE_DBS" ]; then
          log "Backing up SQLite databases..."
          for db in $SQLITE_DBS; do
              if [ -f "$db" ]; then
                  name=$(basename "$db" .db)
                  sqlite3 "$db" ".backup '$DUMP_DIR/$name-$TIMESTAMP.db'"
                  log "  Dumped: $name"
              fi
          done
      fi

      # Dump MariaDB/MySQL databases
      if [ -n "$MYSQL_HOST" ] && [ -n "$MYSQL_DBS" ]; then
          log "Backing up MySQL databases..."
          for db in $MYSQL_DBS; do
              mysqldump -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
                  --single-transaction "$db" | gzip > "$DUMP_DIR/$db-$TIMESTAMP.sql.gz"
              log "  Dumped: $db"
          done
      fi

      # Dump PostgreSQL databases
      if [ -n "$PGHOST" ] && [ -n "$POSTGRES_DBS" ]; then
          log "Backing up PostgreSQL databases..."
          for db in $POSTGRES_DBS; do
              PGPASSWORD="$PGPASSWORD" pg_dump -h "$PGHOST" -U "$PGUSER" "$db" \
                  | gzip > "$DUMP_DIR/$db-$TIMESTAMP.sql.gz"
              log "  Dumped: $db"
          done
      fi

      # Index dumps with bup
      log "Indexing with bup..."
      bup index "$DUMP_DIR"
      bup save -n databases "$DUMP_DIR"

      # Cleanup old dumps (keep bup history, remove raw dumps)
      log "Cleaning up dumps older than $KEEP_DAYS days..."
      find "$DUMP_DIR" -type f -mtime +$KEEP_DAYS -delete

      log "Backup complete!"
    '';

    # Entrypoint with cron setup
    entrypointSh = pkgs.writeText "entrypoint.sh" ''
      #!/bin/bash
      set -e

      SCHEDULE="''${SCHEDULE:-0 3 * * *}"

      # Setup cron job
      echo "$SCHEDULE /app/backup.sh >> /var/log/backup.log 2>&1" > /etc/cron.d/backup
      chmod 0644 /etc/cron.d/backup
      crontab /etc/cron.d/backup

      # Run initial backup if requested
      if [ "$RUN_ON_START" = "true" ]; then
          /app/backup.sh
      fi

      echo "Backup scheduler started. Schedule: $SCHEDULE"
      exec cron -f
    '';

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      services:
        backup-bup:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
            BACKUP_DIR: ${config.backup_dir}
            KEEP_DAYS: "${toString config.keep_days}"
            SCHEDULE: "${config.schedule}"
            RUN_ON_START: "false"
          volumes:
            - ${config.backup_dir}:/backup
            # Mount database files/sockets as needed
            - /opt/containers:/opt/containers:ro
          networks:
            - backup

      networks:
        backup:
          driver: bridge
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "backup-bup-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${dockerfile} $out/Dockerfile
        cp ${backupSh} $out/backup.sh
        cp ${entrypointSh} $out/entrypoint.sh
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.bup pkgs.sops pkgs.age ];
    };
  };
}
