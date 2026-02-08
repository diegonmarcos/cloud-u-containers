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
      services:
        gitea:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
            USER_UID: 1000
            USER_GID: 1000
            GITEA__database__DB_TYPE: ${config.db_type}
            GITEA__database__PATH: /data/gitea/gitea.db
            GITEA__server__DOMAIN: ${config.domain}
            GITEA__server__ROOT_URL: https://${config.domain}/
            GITEA__server__HTTP_PORT: ${toString config.http_port}
            GITEA__server__SSH_DOMAIN: ${config.domain}
            GITEA__server__SSH_PORT: ${toString config.ssh_port}
            GITEA__server__SSH_LISTEN_PORT: 22
            GITEA__server__DISABLE_SSH: "false"
            GITEA__service__DISABLE_REGISTRATION: ${config.disable_registration}
            GITEA__service__REQUIRE_SIGNIN_VIEW: ${config.require_signin_view}
            GITEA__openid__ENABLE_OPENID_SIGNIN: "false"
            GITEA__openid__ENABLE_OPENID_SIGNUP: "false"
            GITEA__ui__DEFAULT_THEME: gitea-dark
            GITEA__repository__DEFAULT_PRIVATE: "true"
          volumes:
            - ./data:/data
            - /etc/timezone:/etc/timezone:ro
            - /etc/localtime:/etc/localtime:ro
          ports:
            - "${toString config.http_port}:${toString config.http_port}"
            - "${toString config.ssh_port}:22"
          networks:
            - proxy
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:${toString config.http_port}/api/healthz"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 30s

      networks:
        proxy:
          external: true
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
