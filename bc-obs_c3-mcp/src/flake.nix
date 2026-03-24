{
  description = "C3 MCP Server — Cloud Control Center MCP transport (stdio + HTTP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "c3-mcp";
      image = "ghcr.io/diegonmarcos/c3-mcp:latest";
      port = 3100;
      mattermost_url = "http://mattermost.app:8065";
    };

    title = "C3 MCP Server";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_c3-mcp/src/flake.nix   ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_c3-mcp/build.sh ship  ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        c3-mcp:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          network_mode: host
          volumes:
            - /opt/ssh-keys/c3-mcp:/root/.ssh:ro
            - /nix/store:/nix/store:ro
            - ~/.nix-profile/bin:/usr/local/nix-bin:ro
            - ~/.config/gcloud:/root/.config/gcloud
            - c3_git_repos:/root/git
          env_file:
            - .secrets
          environment:
            - MCP_HTTP_PORT=${toString config.port}
            - NODE_ENV=production
            - GIT_BASE=/root/git
            - MM_URL=${config.mattermost_url}
            - DAGU_API=http://10.0.0.3:8070
            - PATH=/usr/local/nix-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:${toString config.port}/mcp"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

      volumes:
        c3_git_repos:
          driver: local

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "c3-mcp-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
    });
  };
}
