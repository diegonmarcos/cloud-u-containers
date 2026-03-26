{
  description = "ntfy Push Notifications + syslog-bridge + github-rss";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      domain = buildJson.domain;
      container_name = "ntfy";
      image = "binwiederhier/ntfy";
      port = buildJson.ports.app;
    };

    title = "ntfy Push Notifications + syslog-bridge + github-rss";
    docker = import ../../_shared/docker.nix;

    mkServerConfig = pkgs: pkgs.writeText "server.yml" ''
      # ntfy server configuration (auth enabled)
      base-url: https://${config.domain}

      # Cache and retention
      cache-file: /var/cache/ntfy/cache.db
      cache-duration: 720h
      attachment-cache-dir: /var/cache/ntfy/attachments

      # Limits
      visitor-request-limit-burst: 60
      visitor-request-limit-replenish: 10s
      visitor-message-daily-limit: 0

      # Auth — admin API access (Caddy injects credentials, anonymous r/w preserved)
      auth-file: /var/cache/ntfy/auth.db
      auth-default-access: read-write

      # Web interface
      enable-login: true
      enable-signup: false
      enable-reservations: false

      # Listen on non-default port (host networking — port 80 is Caddy's)
      listen-http: :${toString config.port}

      # Behind reverse proxy (Authelia handles auth)
      behind-proxy: true
    '';

    mkNtfyInit = pkgs: pkgs.writeText "init-ntfy.sh" ''
      #!/bin/sh
      NTFY_PASSWORD="$NTFY_ADMIN_PASSWORD" ntfy user add --role=admin admin 2>/dev/null || true
      NTFY_PASSWORD="$NTFY_ADMIN_PASSWORD" ntfy user change-pass admin 2>/dev/null || true
      NTFY_PASSWORD="$NTFY_USER_PASSWORD" ntfy user add diego 2>/dev/null || true
      NTFY_PASSWORD="$NTFY_USER_PASSWORD" ntfy user change-pass diego 2>/dev/null || true
      exec ntfy serve
    '';

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_ntfy/src/flake.nix";
      volumes = {
        ntfy_cache = {};
      };
      services = {
        ntfy = docker.mkService {
          name = "ntfy";
          image = config.image;
          container_name = config.container_name;
          restart = "no";
          skipReadOnly = true;
          entrypoint = ["/init-ntfy.sh"];
          env_file = [".secrets"];
          environment = ["TZ=Europe/Paris"];
          volumes = [
            "ntfy_cache:/var/cache/ntfy"
            "./etc:/etc/ntfy:ro"
            "./init-ntfy.sh:/init-ntfy.sh:ro"
          ];
        };
        syslog-bridge = docker.mkService {
          name = "syslog-bridge";
          image = "python:3.11-slim";
          container_name = "syslog-bridge";
          restart = "no";
          skipReadOnly = true;
          command = "python -u /app/syslog-to-ntfy.py";
          volumes = [
            "./syslog-to-ntfy.py:/app/syslog-to-ntfy.py:ro"
            "ntfy_cache:/var/cache/ntfy"
            "/var/log:/var/log:ro"
          ];
          environment = ["TZ=Europe/Paris" "PYTHONUNBUFFERED=1"];
          depends_on = { ntfy = {}; };
        };
        github-rss = docker.mkService {
          name = "github-rss";
          image = "python:3.11-slim";
          container_name = "github-rss";
          restart = "no";
          skipReadOnly = true;
          command = "python -u /app/github-rss-to-ntfy.py";
          volumes = [
            "./github-rss-to-ntfy.py:/app/github-rss-to-ntfy.py:ro"
            "ntfy_cache:/var/cache/ntfy"
          ];
          environment = ["TZ=Europe/Paris" "PYTHONUNBUFFERED=1"];
          depends_on = { ntfy = {}; };
        };
      };
    };


  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "ntfy-configs" {} ''
        mkdir -p $out/etc
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkServerConfig pkgs} $out/etc/server.yml
        cp ${./syslog-to-ntfy.py} $out/syslog-to-ntfy.py
        cp ${./github-rss-to-ntfy.py} $out/github-rss-to-ntfy.py
        cp ${./topic-scanner.py} $out/topic-scanner.py
        cp ${mkNtfyInit pkgs} $out/init-ntfy.sh
        chmod +x $out/init-ntfy.sh
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
