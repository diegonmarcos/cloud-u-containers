{
  description = "Radicale Calendar/Contacts (CalDAV/CardDAV) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      domain = buildJson.domain;
      container_name = "radicale";
      image = "tomsquest/docker-radicale:latest";
      port = buildJson.ports.app;
    };

    title = "Radicale Calendar/Contacts (CalDAV/CardDAV)";

    mkRadicaleConfig = pkgs: pkgs.writeText "config" ''
      [server]
      hosts = 0.0.0.0:5232

      [auth]
      type = imap
      imap_host = 10.0.0.3:993
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
            container_name = config.container_name;
            ports = [ "10.0.0.6:${toString config.port}:5232" ];
            networks = [ "default" ];
            volumes = [
              "./data:/data"
              "./config:/config:ro"
            ];
            environment = [
              "TAKE_FILE_OWNERSHIP=true"
            ];
            healthcheck = {
              test = "curl -f http://localhost:5232/.web/ || exit 1";
              interval = "30s";
              timeout = "10s";
              retries = 3;
            };
          };
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
