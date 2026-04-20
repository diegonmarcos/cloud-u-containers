{
  description = "Sauron Central - Syslog collector + SIEM API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # build-sauron-central.json (symlink → I_cloud-data/build-sauron-central.json)
    # tracks the service container declaration; local build.json owns the two
    # co-deployed containers (syslog-central + siem-api) since cloud-data only
    # models a single "sauron-central" role.
    buildSauron = builtins.fromJSON (builtins.readFile ./build-sauron-central.json);

    containers = buildJson.containers;

    config = {
      service_container = buildSauron.container.container_name;
      syslog_container = containers.syslog.container_name;
      api_container = containers.api.container_name;
    };

    title = "Sauron Central";

    # GHCR images: one per container
    ghcrSyslog = docker.mkGhcrBuild {
      name = "sauron-syslog";
      fromImage = containers.syslog.upstream_image;
      configFiles = [
        { src = "syslog-ng-central.conf"; dst = "/etc/syslog-ng/syslog-ng.conf"; }
      ];
    };

    ghcrApi = docker.mkGhcrBuild {
      name = "sauron-api";
      fromImage = containers.api.upstream_image;
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
          container_name = config.syslog_container;
          restart = "no";
          networkMode = "host";
          skipReadOnly = true;
          volumes = [
            "siem-data:/var/log/siem"
            "syslog-state:/var/lib/syslog-ng"
          ];
        };

        siem-api = docker.mkService {
          name = "siem-api";
          image = ghcrApi.image;
          build = ghcrApi.build;
          container_name = config.api_container;
          restart = "no";
          networkMode = "host";
          command = ''["python", "/app/app.py"]'';
          volumes = [
            "siem-data:/var/log/siem"
          ];
          environment = [ "DB_PATH=/var/log/siem/alerts.db" ];
          skipReadOnly = true;
        };
      };

      volumes = {
        siem-data = {};
        syslog-state = {};
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
