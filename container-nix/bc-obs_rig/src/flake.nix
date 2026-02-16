{
  description = "Rig Infrastructure Intelligence - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "rig";
      port = 8090;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        rig:
          build:
            context: .
            dockerfile: Dockerfile
          image: rig-infra:latest
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .secrets
          extra_hosts:
            - "host.docker.internal:host-gateway"
          ports:
            - "127.0.0.1:${toString config.port}:${toString config.port}"
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
          healthcheck:
            test: ["CMD", "curl", "-sf", "http://localhost:${toString config.port}/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "rig-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
