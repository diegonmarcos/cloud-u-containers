{
  description = "C3 MCP Server — Cloud Control Center MCP transport (stdio + HTTP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      container_name = buildJson.name;
      image = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
      port = buildJson.ports.app;
      health_path = buildJson.health.path;
      mattermost_url = "http://mattermost.app:8065";
    };

    title = buildJson.description;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_c3-infra-mcp/src/flake.nix";

      services.${config.container_name} = docker.mkService {
        name = config.container_name;
        image = config.image;
        container_name = config.container_name;
        networkMode = "host";
        skipReadOnly = true;

        env_file = [ ".secrets" ];
        environment = [
          "MCP_HTTP_PORT=${toString config.port}"
          "NODE_ENV=production"
          "GIT_BASE=/root/git"
          "MM_URL=${config.mattermost_url}"
          "DAGU_API=http://10.0.0.3:8070"
          "PATH=/usr/local/nix-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ];
        volumes = [
          "/opt/ssh-keys/${config.container_name}:/root/.ssh:ro"
          "/nix/store:/nix/store:ro"
          "~/.nix-profile/bin:/usr/local/nix-bin:ro"
          "~/.config/gcloud:/root/.config/gcloud"
          "c3_git_repos:/root/git"
        ];
        healthcheck = {
          test = ''["CMD-SHELL", "curl -sf -X POST -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}' http://localhost:${toString config.port}${config.health_path} || exit 1"]'';
          interval = "30s";
          timeout = "10s";
          retries = 3;
          start_period = "15s";
        };
      };

      volumes.c3_git_repos = { external = true; name = "c3-infra-mcp-api_c3_git_repos"; };
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
