{
  description = "ntfy Push Notifications + syslog-bridge + github-rss";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "rss.diegonmarcos.com";
      container_name = "ntfy";
      image = "binwiederhier/ntfy";
      port = 8090;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ntfy - Push Notification Server
      # Deployed on: gcp-E2-f_0 (35.226.147.64)
      # Domain: ${config.domain}

      services:
        ntfy:
          image: ${config.image}
          container_name: ${config.container_name}
          command:
            - serve
          environment:
            - TZ=Europe/Paris
          volumes:
            - ./cache:/var/cache/ntfy
            - ./etc:/etc/ntfy
          ports:
            - '127.0.0.1:${toString config.port}:80'
          restart: unless-stopped
          dns:
            - 8.8.8.8
            - 1.1.1.1
          networks:
            - npm_default

        syslog-bridge:
          image: python:3.11-slim
          container_name: syslog-bridge
          command: python -u /app/syslog-to-ntfy.py
          volumes:
            - ./syslog-to-ntfy.py:/app/syslog-to-ntfy.py:ro
            - ./cache:/var/cache/ntfy
            - syslog-central-logs:/var/log:ro
          environment:
            - TZ=Europe/Paris
            - PYTHONUNBUFFERED=1
          depends_on:
            - ntfy
          restart: unless-stopped
          dns:
            - 8.8.8.8
          networks:
            - npm_default

        github-rss:
          image: python:3.11-slim
          container_name: github-rss
          command: python -u /app/github-rss-to-ntfy.py
          volumes:
            - ./github-rss-to-ntfy.py:/app/github-rss-to-ntfy.py:ro
            - ./cache:/var/cache/ntfy
          environment:
            - TZ=Europe/Paris
            - PYTHONUNBUFFERED=1
          depends_on:
            - ntfy
          restart: unless-stopped
          dns:
            - 8.8.8.8
            - 1.1.1.1
          networks:
            - npm_default

      volumes:
        syslog-central-logs:
          external: true

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "ntfy-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./syslog-to-ntfy.py} $out/syslog-to-ntfy.py
        cp ${./github-rss-to-ntfy.py} $out/github-rss-to-ntfy.py
      '';
    });
  };
}
