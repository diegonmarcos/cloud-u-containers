{
  description = "Borg - Deduplicating backup for media files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      container_name = "backup-borg";
      timezone = "Europe/Madrid";
      backup_dir = "/backup/media";

      # Retention policy
      keep_daily = 7;
      keep_weekly = 4;
      keep_monthly = 6;

      # Schedule (cron format)
      schedule = "0 4 * * *";  # 4 AM daily

      # Compression
      compression = "zstd,3";
    };

    # Dockerfile for borg
    dockerfile = pkgs.writeText "Dockerfile" ''
      FROM debian:bookworm-slim

      RUN apt-get update && apt-get install -y --no-install-recommends \
          borgbackup \
          cron \
          bash \
          openssh-client \
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

      BORG_REPO="''${BORG_REPO:-/backup/borg}"
      SOURCE_DIRS="''${SOURCE_DIRS:-/data}"
      ARCHIVE_NAME="''${ARCHIVE_NAME:-backup}-$(date +%Y%m%d_%H%M%S)"

      KEEP_DAILY="''${KEEP_DAILY:-7}"
      KEEP_WEEKLY="''${KEEP_WEEKLY:-4}"
      KEEP_MONTHLY="''${KEEP_MONTHLY:-6}"
      COMPRESSION="''${COMPRESSION:-zstd,3}"

      export BORG_PASSPHRASE
      export BORG_REPO

      log() {
          echo "[$(date -Iseconds)] $1"
      }

      # Initialize repo if needed
      if [ ! -d "$BORG_REPO/data" ]; then
          log "Initializing Borg repository..."
          borg init --encryption=repokey-blake2 "$BORG_REPO"
      fi

      log "Starting backup: $ARCHIVE_NAME"
      log "Source directories: $SOURCE_DIRS"

      # Create backup
      borg create \
          --verbose \
          --filter AME \
          --list \
          --stats \
          --show-rc \
          --compression "$COMPRESSION" \
          --exclude-caches \
          --exclude '*.tmp' \
          --exclude '*.log' \
          --exclude '*/.cache/*' \
          --exclude '*/cache/*' \
          --exclude '*/thumbnails/*' \
          "::$ARCHIVE_NAME" \
          $SOURCE_DIRS

      log "Pruning old archives..."
      borg prune \
          --list \
          --show-rc \
          --keep-daily=$KEEP_DAILY \
          --keep-weekly=$KEEP_WEEKLY \
          --keep-monthly=$KEEP_MONTHLY

      log "Compacting repository..."
      borg compact

      log "Repository info:"
      borg info

      log "Backup complete!"
    '';

    # Entrypoint with cron setup
    entrypointSh = pkgs.writeText "entrypoint.sh" ''
      #!/bin/bash
      set -e

      SCHEDULE="''${SCHEDULE:-0 4 * * *}"

      # Export passphrase for cron
      echo "BORG_PASSPHRASE=$BORG_PASSPHRASE" >> /etc/environment
      echo "BORG_REPO=$BORG_REPO" >> /etc/environment

      # Setup cron job
      echo "$SCHEDULE /app/backup.sh >> /var/log/borg.log 2>&1" > /etc/cron.d/borg
      chmod 0644 /etc/cron.d/borg
      crontab /etc/cron.d/borg

      # Run initial backup if requested
      if [ "$RUN_ON_START" = "true" ]; then
          /app/backup.sh
      fi

      echo "Borg backup scheduler started. Schedule: $SCHEDULE"
      exec cron -f
    '';

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      services:
        backup-borg:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
            BORG_REPO: ${config.backup_dir}/borg
            KEEP_DAILY: "${toString config.keep_daily}"
            KEEP_WEEKLY: "${toString config.keep_weekly}"
            KEEP_MONTHLY: "${toString config.keep_monthly}"
            COMPRESSION: "${config.compression}"
            SCHEDULE: "${config.schedule}"
            RUN_ON_START: "false"
          volumes:
            - ${config.backup_dir}:/backup
            # Source directories to backup
            - /opt/containers/photoprism/originals:/data/photos:ro
            - /opt/containers/syncthing/data:/data/syncthing:ro
            - /opt/containers/radicale/data:/data/calendar:ro
          networks:
            - backup

      networks:
        backup:
          driver: bridge
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "backup-borg-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${dockerfile} $out/Dockerfile
        cp ${backupSh} $out/backup.sh
        cp ${entrypointSh} $out/entrypoint.sh
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.borgbackup pkgs.sops pkgs.age ];
    };
  };
}
