{
  description = "Radicale Calendar/Contacts (CalDAV/CardDAV) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "cal.diegonmarcos.com";
      container_name = "radicale";
      image = "tomsquest/docker-radicale:latest";
      port = 5232;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        radicale:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          expose:
            - "5232"
          volumes:
            - ./data:/data
            - ./config:/config:ro
          environment:
            - RADICALE_CONFIG=/config/config
          networks:
            - calendar_net
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:5232/.web/"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s

        caddy:
          image: caddy:alpine
          container_name: caddy-calendar
          restart: unless-stopped
          ports:
            - "80:80"
            - "443:443"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - caddy_data:/data
            - caddy_config:/config
          networks:
            - calendar_net
          depends_on:
            - radicale

      networks:
        calendar_net:
          driver: bridge

      volumes:
        caddy_data:
        caddy_config:
    '';

    mkRadicaleConfig = pkgs: pkgs.writeText "config" ''
      [server]
      hosts = 0.0.0.0:5232

      [auth]
      type = htpasswd
      htpasswd_filename = /config/users
      htpasswd_encryption = bcrypt

      [storage]
      filesystem_folder = /data/collections

      [logging]
      level = info
    '';

    mkUsersFile = pkgs: pkgs.writeText "users" ''
      # Generate with: htpasswd -nB username
      # diego:$2y$05$CHANGE_ME_BCRYPT_HASH
    '';

    mkCaddyFile = pkgs: pkgs.writeText "Caddyfile" ''
      cal.diegonmarcos.com {
          reverse_proxy radicale:5232
      }
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "radicale-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        mkdir -p $out/config
        cp ${./config/config} $out/config/config
        cp ${./Caddyfile} $out/Caddyfile
      '';
    });
  };
}
