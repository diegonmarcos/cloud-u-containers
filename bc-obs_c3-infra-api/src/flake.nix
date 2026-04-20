{
  description = "C3 REST API — Cloud Control Center Fastify API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    lib = nixpkgs.lib;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-c3-infra-api.json (symlink → I_cloud-data/).
    # Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-c3-infra-api.json);
    svc = buildContainer.services;

    # base_domain derived from proxy parent_domain
    # e.g. "api.diegonmarcos.com" → "diegonmarcos.com"
    parent_domain = buildJson.proxy.primary.parent_domain;
    base_domain =
      let parts = lib.splitString "." parent_domain;
      in lib.concatStringsSep "." (lib.drop 1 parts);
    auth_domain = "auth.${base_domain}";

    config = {
      container_name = buildContainer.container.container_name;
      image = buildContainer.container.image;
      port = buildContainer.container.port;
      base_domain = base_domain;
      auth_domain = auth_domain;
      auth_token_url = "https://${auth_domain}/api/oidc/token";
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
        portEnv = ports.envFor "app";

        env_file = [ ".secrets" ];
        environment = [
          "HOST=${svc."c3-infra-api".ip}"
          "NODE_ENV=production"
          "GIT_BASE=/root/git"
          "AUTHELIA_OIDC_CLIENT_ID=${config.container_name}"
          "AUTHELIA_OIDC_CLIENT_SECRET=\${AUTHELIA_OIDC_C3_INFRA_MCP_SECRET}"
          "AUTHELIA_TOKEN_URL=${config.auth_token_url}"
          "RESEND_API_KEY=\${RESEND_API_KEY}"
          "CF_API_KEY=\${CF_API_KEY}"
          "CF_API_EMAIL=\${CF_API_EMAIL}"
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
          test = ''["CMD", "curl", "-f", "http://${svc."c3-infra-api".ip}:${toString config.port}/health"]'';
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
