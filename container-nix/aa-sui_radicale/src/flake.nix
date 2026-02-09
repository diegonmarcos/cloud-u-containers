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
          ports:
            - "${toString config.port}:5232"
          volumes:
            - ./data:/data
            - ./config:/config:ro
          environment:
            - TAKE_FILE_OWNERSHIP=true
          healthcheck:
            test: curl -f http://localhost:5232/.web/ || exit 1
            interval: 30s
            timeout: 10s
            retries: 3
          networks:
            - mail_network
            - mailu_default

      networks:
        mail_network:
          external: true
        mailu_default:
          external: true
    '';

    mkRadicaleConfig = pkgs: pkgs.writeText "config" ''
      [server]
      hosts = 0.0.0.0:5232

      [auth]
      type = imap
      imap_host = imap:143
      imap_security = none

      [storage]
      filesystem_folder = /data/collections

      [rights]
      type = owner_only

      [logging]
      level = debug

      [web]
      type = internal
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "radicale-configs" {} ''
        mkdir -p $out/config
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkRadicaleConfig pkgs} $out/config/config
      '';
    });
  };
}
