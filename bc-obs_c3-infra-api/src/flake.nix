{
  description = "C3 REST API — Cloud Control Center Fastify API";

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
    };

    title = buildJson.description;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_c3-infra-api/src/flake.nix";

      services.${config.container_name} = docker.mkService {
        name = config.container_name;
        image = config.image;
        container_name = config.container_name;
        networkMode = "host";
        skipReadOnly = true;

        env_file = [ ".secrets" ];
        environment = [
          "PORT=${toString config.port}"
          "NODE_ENV=production"
          "GIT_BASE=/root/git"
          "AUTHELIA_OIDC_CLIENT_ID=${config.container_name}"
          "AUTHELIA_OIDC_CLIENT_SECRET=\${AUTHELIA_OIDC_C3_INFRA_MCP_SECRET}"
          "AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token"
          "RESEND_API_KEY=\${RESEND_API_KEY}"
          "CF_API_KEY=\${CF_API_KEY}"
          "CF_API_EMAIL=\${CF_API_EMAIL}"
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
          test = ''["CMD", "curl", "-f", "http://localhost:${toString config.port}/health"]'';
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
