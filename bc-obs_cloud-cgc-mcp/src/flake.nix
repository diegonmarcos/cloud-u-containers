{
  description = "Code Graph Context MCP Server — infra knowledge, octocode, codegraph (HTTP + stdio)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      container_name = buildJson.name;
      image = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
      http_port = toString buildJson.ports.app;
      # CONFIG_PATH points to config.json; getRepoRoot() = parent dir
      # So /data/config.json -> getRepoRoot() = /data/
      # Then cloud-data/ = /data/cloud-data/, front-data/ = /data/front-data/
      data_path = "/data";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔═════════════════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY                    ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!                         ║
      # ╠═════════════════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_cloud-cgc-mcp/                      ║
      # ║ Rebuild: build.sh ship                                                     ║
      # ╚═════════════════════════════════════════════════════════════════════════════╝
      volumes:
        octocode_db:
          external: true
        octocode_repos:
          external: true

      services:
        cloud-cgc-mcp:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
          environment:
            MCP_TRANSPORT: http
            MCP_HTTP_PORT: "${config.http_port}"
            CONFIG_PATH: "${config.data_path}/config.json"
            GIT_ROOT: "/repos"
          volumes:
            - ./data:${config.data_path}:ro
            - octocode_db:/root/.local/share/octocode:ro
            - octocode_repos:/repos:ro
          healthcheck:
            test: ["CMD", "node", "-e", "fetch('http://localhost:${config.http_port}/mcp').catch(()=>process.exit(1))"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "${config.container_name}-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
