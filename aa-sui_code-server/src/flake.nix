{
  description = "Code Server (VS Code in browser) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    config = {
      domain = "ide.diegonmarcos.com";
      container_name = "code-server";
      image = "linuxserver/code-server:latest";
      port = 8443;
      timezone = "Europe/Madrid";
    };

    title = "Code Server (VS Code in browser)";

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_code-server/src/flake.nix";
        services = {
          code-server = docker.mkService {
            name = "code-server";
            image = config.image;
            container_name = config.container_name;
            ports = [ "10.0.0.6:${toString config.port}:8443" ];
            networks = [ "infra" ];
            networkIps = { infra = "172.21.0.61"; };
            dns = [ "172.21.0.2" ];
            volumes = [
              "./config:/config"
              "/home/ubuntu/workspace:/workspace"
            ];
            environment = {
              TZ = config.timezone;
              PUID = "1000";
              PGID = "1000";
              DEFAULT_WORKSPACE = "/workspace";
            };
            skipReadOnly = true;
          };
        };
        networks = {
          infra = {
            external = true;
          };
        };
      };

      defaultPkg = pkgs.runCommand "code-server-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
