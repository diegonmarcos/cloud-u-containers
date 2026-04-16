{
  description = "Introspect Proxy — OIDC token validation sidecar for Caddy Bearer auth";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      port = toString buildJson.ports.app;
    };

    title = "Introspect Proxy";
    docker = import ../../_shared/docker.nix;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bb-sec_introspect-proxy/src/flake.nix";
      services = {
        introspect-proxy = docker.mkService {
          name = "introspect-proxy";
          image = "ghcr.io/diegonmarcos/introspect-proxy:latest";
          container_name = "introspect-proxy";
          skipReadOnly = true;
          memLimit = "64M";
          memReservation = "16M";
          healthcheck = {
            test = "['CMD', 'curl', '-sf', 'http://localhost:${config.port}/health']";
            interval = "30s";
            timeout = "10s";
            retries = 3;
          };
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "introspect-proxy-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
