{
  description = "Grist - Modern collaborative spreadsheet (Google Sheets alternative)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      domain = buildJson.domain;
      container_name = "grist_app";
      image = "gristlabs/grist:latest";
      port = buildJson.ports.app;
    };

    title = "Grist - Modern collaborative spreadsheet (Google Sheets alternative)";

    ghcr = docker.mkGhcrBuild {
      name = "grist";
      fromImage = config.image;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_grist/src/flake.nix";
        services = {
          grist = docker.mkService {
            name = "grist";
            image = ghcr.image;
            build = ghcr.build;
            container_name = config.container_name;
            portEnv = ports.envFor "app";
            skipReadOnly = true;
            volumes = [
              "grist_data:/persist"
            ];
            environment = [
              "GRIST_SESSION_SECRET=changeme-secret-key"
              "GRIST_SINGLE_ORG=docs"
              "GRIST_DEFAULT_EMAIL=\${GRIST_ADMIN_EMAIL:-admin@diegonmarcos.com}"
              "APP_HOME_URL=https://${config.domain}"
              "GRIST_SANDBOX_FLAVOR=unsandboxed"
              "GRIST_LOG_LEVEL=info"
            ];
            restart = "no";  # container-init handles startup
            healthcheck = {
              test = "['CMD', 'curl', '-f', 'http://localhost:${toString config.port}/']";
              interval = "30s";
              timeout = "10s";
              retries = 3;
            };
          };
        };
        volumes = {
          grist_data = {};
        };
      };

      defaultPkg = pkgs.runCommand "grist-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
