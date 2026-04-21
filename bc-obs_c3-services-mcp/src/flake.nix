{
  description = "C3 Services MCP Server — service API gateway MCP transport";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-c3-services-mcp.json (symlink → 2_configs/dist/).
    # Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-c3-services-mcp.json);
    svc = buildContainer.services;

    config = {
      container_name = buildContainer.container.container_name;
      image = buildContainer.container.image;
      port = buildContainer.container.port;
      health_path = buildContainer.container.healthcheck;
    };

    title = buildJson.description;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_c3-services-mcp/src/flake.nix";

      services.${config.container_name} = docker.mkService {
        name = config.container_name;
        image = config.image;
        container_name = config.container_name;
        networkMode = null;  # bridge mode — port mapping binds to WG IP only
        ports = ["${svc."c3-services-mcp".ip}:${toString config.port}:${toString config.port}"];
        skipReadOnly = true;
        portEnv = ports.envFor "app";

        env_file = [ ".secrets" ];
        environment = [
          "NODE_ENV=production"
        ];
        healthcheck = {
          test = ''["CMD-SHELL", "curl -so /dev/null -w '%{http_code}' http://localhost:${toString config.port}${config.health_path} | grep -qE '^[2-4]' || exit 1"]'';
          interval = "30s";
          timeout = "10s";
          retries = 3;
          start_period = "15s";
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "${config.container_name}-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
