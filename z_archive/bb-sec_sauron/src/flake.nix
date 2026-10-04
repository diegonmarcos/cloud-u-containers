{
  description = "Sauron - YARA-based security scanner (full version)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        sauron:
          container_name: sauron
          image: sauron-sauron:latest
          restart: unless-stopped
          volumes:
            - /etc:/watch/etc:ro
            - /home:/watch/home:ro
            - /var/www:/watch/www:ro
            - /var/lib/docker/volumes:/watch/docker-volumes:ro
            - ./yara-rules:/etc/sauron/yara-rules:ro
            - ./entrypoint.sh:/entrypoint.sh:ro
            - sauron-logs:/var/log/sauron
          environment:
            - RULES_DIR=/etc/sauron/yara-rules
            - WATCH_DIR=/watch
            - OUTPUT_FILE=/var/log/sauron/alerts.jsonl
          logging:
            driver: "json-file"
            options:
              max-size: "10m"
              max-file: "3"
          networks:
            - security

        syslog-forwarder:
          image: balabit/syslog-ng:4.4.0
          container_name: syslog-forwarder
          restart: unless-stopped
          volumes:
            - ./config/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro
            - sauron-logs:/var/log/sauron:ro
            - syslog-cache:/var/cache/syslog-ng
          environment:
            - CENTRAL_HOST=''${CENTRAL_HOST:-34.55.55.234}
            - CENTRAL_PORT=''${CENTRAL_PORT:-5514}
            - VM_NAME=''${VM_NAME:-unknown}
          depends_on:
            - sauron
          networks:
            - security

      volumes:
        sauron-logs:
        syslog-cache:

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
