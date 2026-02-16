{
  description = "Gitea - Lightweight self-hosted Git server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "git.diegonmarcos.com";
      container_name = "gitea";
      image = "gitea/gitea:latest";
      http_port = 3000;
      ssh_port = 2222;
      timezone = "Europe/Madrid";

      # Database (SQLite by default, or use external PostgreSQL)
      db_type = "sqlite3";

      # App settings
      app_name = "Diego Git";
      disable_registration = "true";
      require_signin_view = "true";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Gitea - Self-hosted Git server for code mirrors
      # Deploy to: oci-A1-f_1

      services:
        gitea:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            - USER_UID=1000
            - USER_GID=1000
            - GITEA__database__DB_TYPE=${config.db_type}
            - GITEA__database__PATH=/data/gitea/gitea.db
            - GITEA__server__ROOT_URL=http://144.24.196.72:${toString config.http_port}
            - GITEA__server__SSH_PORT=${toString config.ssh_port}
            - GITEA__server__SSH_DOMAIN=144.24.196.72
            - GITEA__mirror__ENABLED=true
            - GITEA__mirror__DEFAULT_INTERVAL=1h
          volumes:
            - gitea_data:/data
            - /etc/timezone:/etc/timezone:ro
            - /etc/localtime:/etc/localtime:ro
          ports:
            - "${toString config.http_port}:${toString config.http_port}"
            - "${toString config.ssh_port}:22"
          networks:
            - backup_network

      volumes:
        gitea_data:
          driver: local
          driver_opts:
            type: none
            o: bind
            device: /backup/code/gitea-data

      networks:
        backup_network:
          driver: bridge
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "gitea-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
