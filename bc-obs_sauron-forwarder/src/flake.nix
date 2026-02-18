{
  description = "Sauron Forwarder - Alert forwarding to central sauron via netcat";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "sauron-forwarder";
      image = "debian:bookworm-slim";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        sauron-forwarder:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            - CENTRAL_HOST=''${CENTRAL_HOST}
            - CENTRAL_PORT=''${CENTRAL_PORT:-5514}
          volumes:
            - sauron-data:/var/log/sauron:ro
          entrypoint: ["/bin/sh", "-c"]
          command:
            - |
              apt-get update && apt-get install -y --no-install-recommends netcat-openbsd && rm -rf /var/lib/apt/lists/*
              echo "Forwarding alerts to $${CENTRAL_HOST}:$${CENTRAL_PORT}"
              tail -F /var/log/sauron/alerts.jsonl 2>/dev/null | while read line; do
                echo "$$line" | nc -w1 $${CENTRAL_HOST} $${CENTRAL_PORT} 2>/dev/null || true
              done
          networks:
            - security

      networks:
        security:
          name: sauron-lite_security
          external: true

      volumes:
        sauron-data:
          name: sauron-lite_sauron-data
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "sauron-forwarder-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
