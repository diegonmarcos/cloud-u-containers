{
  description = "Filebrowser - Web file manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "files.diegonmarcos.com";
      container_name = "filebrowser_app";
      image = "filebrowser/filebrowser:latest";
      port = 3015;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Filebrowser - Web file manager
      # Deployed on: oci-A1-f_1 (Oracle Flex)

      services:
        filebrowser:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"
          ports:
            - "10.0.0.2:${toString config.port}:80"
          volumes:
            - filebrowser_data:/srv
            - filebrowser_db:/database
            - filebrowser_config:/config
          environment:
            - PUID=1000
            - PGID=1000
            - FB_DATABASE=/database/filebrowser.db
            - FB_CONFIG=/config/settings.json
            - FB_ROOT=/srv
            - FB_NOAUTH=false
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:80/health']
            interval: 30s
            timeout: 10s
            retries: 3

      networks:
        dev_network:
          external: true
          name: dev_network

      volumes:
        filebrowser_data:
          driver: local
        filebrowser_db:
          driver: local
        filebrowser_config:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "filebrowser-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
