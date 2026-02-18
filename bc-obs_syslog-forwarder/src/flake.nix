{
  description = "Syslog Forwarder - syslog-ng log forwarding to central server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "syslog-forwarder";
      image = "balabit/syslog-ng:4.4.0";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        syslog-forwarder:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            - VM_NAME=''${VM_NAME:-unknown}
            - CENTRAL_HOST=''${CENTRAL_HOST}
            - CENTRAL_PORT=''${CENTRAL_PORT:-5514}
          volumes:
            - /opt/sauron/config/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro
            - sauron-logs:/var/log/sauron:ro
            - syslog-cache:/var/cache/syslog-ng
          networks:
            - security

      networks:
        security:
          name: sauron_security
          external: true

      volumes:
        sauron-logs:
          name: sauron_sauron-logs
          external: true
        syslog-cache:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "syslog-forwarder-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
