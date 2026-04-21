{
  description = "Code Graph Context MCP Server — infra knowledge, octocode, codegraph (HTTP + stdio)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-cloud-cgc-mcp.json (symlink → 2_configs/dist/).
    # Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-cloud-cgc-mcp.json);

    config = {
      container_name = buildContainer.container.container_name;
      image = buildContainer.container.image;
      port = buildContainer.container.port;
      port_env = buildContainer.container.port_env;
      health_path = buildContainer.container.healthcheck;
      # CONFIG_PATH points to config.json; getRepoRoot() = parent dir
      # So /data/config.json -> getRepoRoot() = /data/
      # Then cloud-data/ = /data/cloud-data/, front-data/ = /data/front-data/
      data_path = buildJson.runtime.data_path;
      git_root = buildJson.runtime.git_root;
    };

    title = buildJson.description;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_cloud-cgc-mcp/src/flake.nix";

      services.${config.container_name} = docker.mkService {
        name = config.container_name;
        image = config.image;
        container_name = config.container_name;
        networkMode = "host";
        skipReadOnly = true;
        portEnv = ports.envFor "app";

        environment = {
          MCP_TRANSPORT = "http";
          CONFIG_PATH = "${config.data_path}/config.json";
          GIT_ROOT = config.git_root;
        };
        volumes = [
          "./data:${config.data_path}:ro"
        ];
        healthcheck = {
          test = ''["CMD", "node", "-e", "fetch('http://localhost:${toString config.port}${config.health_path}').catch(()=>process.exit(1))"]'';
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
