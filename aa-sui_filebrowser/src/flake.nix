{
  description = "Filebrowser - Web file manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    svc = (builtins.fromJSON (builtins.readFile ./cloud-data-service-connections.json)).services;

    config = {
      domain = buildJson.domain;
      container_name = "filebrowser_app";
      image = "filebrowser/filebrowser:latest";
      port = buildJson.ports.app;
    };

    title = "Filebrowser - Web file manager";

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_filebrowser/src/flake.nix";
        services = {
          filebrowser = docker.mkService {
            name = "filebrowser";
            image = config.image;
            container_name = config.container_name;
            networkMode = null;
            ports = [ "${svc.filebrowser.ip}:${toString config.port}:8080" ];
            dns = [svc.filebrowser.ip];
            volumes = [
              "filebrowser_data:/srv"
              "filebrowser_db:/database"
              "filebrowser_config:/config"
            ];
            environment = [
              "PUID=1000"
              "PGID=1000"
              "FB_DATABASE=/database/filebrowser.db"
              "FB_CONFIG=/config/settings.json"
              "FB_ROOT=/srv"
              "FB_NOAUTH=false"
              "FB_LOG=stdout"
              "FB_PORT=8080"
            ];
            healthcheck = {
              test = "['CMD', 'wget', '-q', '--spider', 'http://localhost:8080/health']";
              interval = "30s";
              timeout = "10s";
              retries = 3;
            };
          };
        };
        volumes = {
          filebrowser_data = {};
          filebrowser_db = {};
          filebrowser_config = {};
        };
      };

      defaultPkg = pkgs.runCommand "filebrowser-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
