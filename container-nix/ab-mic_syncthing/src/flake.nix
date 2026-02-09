{
  description = "Syncthing File Sync - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "syncthing";
      image = "syncthing/syncthing:latest";
      web_port = 8384;
      sync_port = 22000;
      discovery_port = 21027;
      timezone = "Europe/Madrid";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        syncthing:
          image: ${config.image}
          container_name: ${config.container_name}
          hostname: web-server-1
          restart: unless-stopped
          environment:
            - PUID=1000
            - PGID=1000
          volumes:
            - /home/ubuntu/syncthing-config:/var/syncthing/config
            - /home/ubuntu/sync:/var/syncthing/data
          ports:
            - "${toString config.web_port}:8384"
            - "${toString config.sync_port}:22000"
            - "${toString config.discovery_port}:21027/udp"
          networks:
            - matomo_default
          deploy:
            resources:
              limits:
                memory: 150M
              reservations:
                memory: 50M

      networks:
        matomo_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "syncthing-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
