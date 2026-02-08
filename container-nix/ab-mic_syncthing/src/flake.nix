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
          restart: unless-stopped
          hostname: syncthing-server
          environment:
            TZ: ${config.timezone}
            PUID: 1000
            PGID: 1000
          ports:
            - "${toString config.web_port}:8384"
            - "${toString config.sync_port}:22000/tcp"
            - "${toString config.sync_port}:22000/udp"
            - "${toString config.discovery_port}:21027/udp"
          volumes:
            - ./config:/var/syncthing/config
            - ./data:/var/syncthing/data
          networks:
            - proxy

      networks:
        proxy:
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
