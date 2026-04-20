{
  description = "Radicale Calendar/Contacts (CalDAV/CardDAV) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    buildContainer = builtins.fromJSON (builtins.readFile ./build-radicale.json);
    svc = buildContainer.services;

    # GHCR image: bake config into image (no bind mount needed)
    ghcr = docker.mkGhcrBuild {
      name = "radicale";
      fromImage = buildJson.upstream_image;
      configFiles = [
        { src = "config/config"; dst = "/config/config"; }
      ];
    };

    config = {
      domain = buildJson.domain;
      container_name = buildContainer.container.container_name;
      image = ghcr.image;
      port = buildJson.ports.app;
    };

    title = "Radicale Calendar/Contacts (CalDAV/CardDAV)";

    mkRadicaleConfig = pkgs: pkgs.writeText "config" ''
      [server]
      hosts = 0.0.0.0:${toString config.port}

      [auth]
      type = imap
      imap_host = ${svc.maddy.ip}:${toString svc.maddy.ports.imap}
      imap_security = tls

      [storage]
      filesystem_folder = /data/collections

      [rights]
      type = owner_only

      [logging]
      level = debug

      [web]
      type = internal
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_radicale/src/flake.nix";
        services = {
          radicale = docker.mkService {
            name = "radicale";
            image = config.image;
            build = ghcr.build;
            container_name = config.container_name;
            networkMode = null;  # bridge mode — port mapping binds to WG IP only
            ports = [ "${svc.radicale.ip}:${toString config.port}:${toString config.port}" ];
            networks = [ "default" ];
            volumes = [
              "radicale_data:/data"
            ];
            environment = [
              "TAKE_FILE_OWNERSHIP=true"
            ];
            healthcheck = {
              test = "curl -f http://localhost:${toString config.port}/.web/ || exit 1";
              interval = "30s";
              timeout = "10s";
              retries = 3;
            };
          };
        };
        volumes = {
          radicale_data = {};
        };
        networks = {
          default = {};
        };
      };

      defaultPkg = pkgs.runCommand "radicale-configs" {} ''
        mkdir -p $out/config
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${mkRadicaleConfig pkgs} $out/config/config
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
