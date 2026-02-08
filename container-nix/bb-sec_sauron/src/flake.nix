{
  description = "Sauron - YARA-based security scanner (full version)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        sauron:
          container_name: sauron
          restart: unless-stopped
          build:
            context: .
            dockerfile: Dockerfile.sauron
          cpus: "0.25"
          mem_limit: 256m
          volumes:
            - /etc:/watch/etc:ro
            - /var/lib/docker/volumes:/watch/docker-volumes:ro
            - ./yara-rules:/etc/sauron/yara-rules:ro
            - ./entrypoint.sh:/entrypoint.sh:ro
          environment:
            - RULES_DIR=/etc/sauron/yara-rules/custom
            - WATCH_DIR=/watch
            - SCAN_INTERVAL=3600
            - WORKERS=1
          logging:
            driver: "json-file"
            options:
              max-size: "10m"
              max-file: "3"
          networks:
            - security

        collector:
          container_name: collector
          build:
            context: ./collector
            dockerfile: Dockerfile
          restart: unless-stopped
          cpus: "0.05"
          mem_limit: 32m
          volumes:
            - /var/log/journal:/var/log/journal:ro
            - /run/log/journal:/run/log/journal:ro
            - /etc/machine-id:/etc/machine-id:ro
            - /var/run/docker.sock:/var/run/docker.sock:ro
          environment:
            - API_URL=https://alerts.diegonmarcos.com
            - NTFY_URL=https://rss.diegonmarcos.com
            - VM_NAME=''${VM_NAME:-oci-flex}
            - CHECK_INTERVAL=30
          depends_on:
            - sauron
          network_mode: host

      volumes:
        sauron-logs:

      networks:
        security:
          driver: bridge
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "sauron-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        mkdir -p $out/collector
        mkdir -p $out/config
        mkdir -p $out/yara-rules/custom
        cp ${./Dockerfile.sauron} $out/Dockerfile.sauron
        cp ${./entrypoint.sh} $out/entrypoint.sh
        cp ${./config/sauron.yml} $out/config/sauron.yml
        cp ${./config/syslog-ng.conf} $out/config/syslog-ng.conf
        cp ${./yara-rules/custom/cryptominers.yar} $out/yara-rules/custom/cryptominers.yar
        cp ${./yara-rules/custom/suspicious.yar} $out/yara-rules/custom/suspicious.yar
        cp ${./yara-rules/custom/webshells.yar} $out/yara-rules/custom/webshells.yar
        cp ${./collector/Dockerfile} $out/collector/Dockerfile
        cp ${./collector/collector.sh} $out/collector/collector.sh
      '';
    });
  };
}
