{
  # Engine consolidation test 2026-04-15
  description = "C3 MCP Server — Cloud Control Center MCP transport (stdio + HTTP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    svc = (builtins.fromJSON (builtins.readFile ./cloud-data-service-connections.json)).services;

    config = {
      container_name = buildJson.name;
      image = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
      port = buildJson.ports.app;
      health_path = buildJson.health.path;
      mattermost_url = "http://mattermost.app";
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
        portEnv = ports.envFor "app";

        env_file = [ ".secrets" ];
        environment = [
          "NODE_ENV=production"
          "GIT_BASE=/root/git"
          "MM_URL=${config.mattermost_url}"
          "DAGU_API=http://${svc.dagu.ip}:${toString svc.dagu.ports.app}"
          "PATH=/usr/local/nix-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ];
        volumes = [
          "/opt/ssh-keys/${config.container_name}:/root/.ssh:ro"
          "/nix/store:/nix/store:ro"
          "/home/ubuntu/.nix-profile/bin:/usr/local/nix-bin:ro"
          "~/.config/gcloud:/root/.config/gcloud"
          "c3_git_repos:/root/git"
        ];
        healthcheck = {
          test = ''["CMD-SHELL", "curl -so /dev/null -w '%{http_code}' http://localhost:${toString config.port}${config.health_path} | grep -qE '^[2-4]' || exit 1"]'';
          interval = "30s";
          timeout = "10s";
          retries = 3;
          start_period = "15s";
        };
      };

      volumes.c3_git_repos = { external = true; name = "c3-mcp-api_c3-repos"; };
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
