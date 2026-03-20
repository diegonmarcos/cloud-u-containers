{
  description = "Filebrowser - Web file manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    config = {
      domain = "files.diegonmarcos.com";
      container_name = "filebrowser_app";
      image = "filebrowser/filebrowser:latest";
      port = 3015;
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
            ports = [ "10.0.0.6:${toString config.port}:80" ];
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
            ];
            healthcheck = {
              test = "['CMD', 'wget', '-q', '--spider', 'http://localhost:80/health']";
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
