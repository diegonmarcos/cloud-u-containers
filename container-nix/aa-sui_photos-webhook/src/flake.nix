{
  description = "Photos Webhook - PostgreSQL + webhook processor for PhotoPrism";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      db_container = "photos-db";
      db_image = "postgres:16-alpine";
      webhook_container = "photos-webhook";
      db_name = "photos";
      db_user = "photos_user";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        photos-db:
          image: ${config.db_image}
          container_name: ${config.db_container}
          environment:
            POSTGRES_DB: ${config.db_name}
            POSTGRES_USER: ${config.db_user}
            POSTGRES_PASSWORD: ''${DB_PASSWORD:-SECURE_PASSWORD_HERE}
          volumes:
            - photos_db_data:/var/lib/postgresql/data
            - ./schema.sql:/docker-entrypoint-initdb.d/01-schema.sql
          ports:
            - "5432:5432"
          networks:
            - photos_net
          restart: unless-stopped
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ${config.db_user} -d ${config.db_name}"]
            interval: 10s
            timeout: 5s
            retries: 5

        photos-webhook:
          build:
            context: .
            dockerfile: Dockerfile
          container_name: ${config.webhook_container}
          environment:
            DB_HOST: ${config.db_container}
            DB_NAME: ${config.db_name}
            DB_USER: ${config.db_user}
            DB_PASSWORD: ''${DB_PASSWORD:-SECURE_PASSWORD_HERE}
            S3_ACCESS_KEY: ''${S3_ACCESS_KEY}
            S3_SECRET_KEY: ''${S3_SECRET_KEY}
            S3_REGION: eu-marseille-1
            S3_BUCKET: photos
            WEBHOOK_PORT: 5001
          ports:
            - "5001:5001"
          depends_on:
            photos-db:
              condition: service_healthy
          volumes:
            - ./webhook.py:/app/webhook.py
            - ./requirements.txt:/app/requirements.txt
          networks:
            - photos_net
          restart: unless-stopped
          command: python webhook.py flask
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
            interval: 10s
            timeout: 5s
            retries: 5

      volumes:
        photos_db_data:
          driver: local

      networks:
        photos_net:
          driver: bridge
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "photos-webhook-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
