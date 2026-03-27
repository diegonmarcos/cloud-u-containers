{
  description = "Sauron Central - Syslog collector + SIEM API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {};

    title = "Sauron Central";
    docker = import ../../_shared/docker.nix;

    # GHCR images: one per container
    ghcrSyslog = docker.mkGhcrBuild {
      name = "sauron-syslog";
      fromImage = "balabit/syslog-ng:4.4.0";
      configFiles = [
        { src = "syslog-ng-central.conf"; dst = "/etc/syslog-ng/syslog-ng.conf"; }
      ];
    };

    ghcrApi = docker.mkGhcrBuild {
      name = "sauron-api";
      fromImage = "python:3.11-slim";
      configFiles = [
        { src = "api/app.py"; dst = "/app/app.py"; }
      ];
    };

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bb-sec_sauron-central/src/flake.nix";

      services = {
        syslog-central = docker.mkService {
          name = "syslog-central";
          image = ghcrSyslog.image;
          build = ghcrSyslog.build;
          container_name = "syslog-central";
          restart = "no";
          networkMode = "host";
          volumes = [
            "siem-data:/var/log/siem"
          ];
        };

        siem-api = docker.mkService {
          name = "siem-api";
          image = ghcrApi.image;
          build = ghcrApi.build;
          container_name = "siem-api";
          restart = "no";
          networkMode = "host";
          command = ''["python", "/app/app.py"]'';
          volumes = [
            "siem-data:/var/log/siem:ro"
          ];
          environment = [ "DB_PATH=/var/log/siem/alerts.db" ];
          skipReadOnly = true;
        };
      };

      volumes = {
        siem-data = {};
      };
    };


    # ── Documentation ────────────────────────────────────────────────────
    mkDocs = pkgs: defaultPkg: docker.mkDocs pkgs {
      inherit title config defaultPkg;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "sauron-central-configs" {} ''
        mkdir -p $out/api
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./syslog-ng-central.conf} $out/syslog-ng-central.conf
        cp ${./api/app.py} $out/api/app.py
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
