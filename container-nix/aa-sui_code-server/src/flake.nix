{
  description = "Code Server (VS Code in browser) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "ide.diegonmarcos.com";
      container_name = "code-server";
      image = "linuxserver/code-server:latest";
      port = 8443;
      timezone = "Europe/Madrid";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        code-server:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
            PUID: 1000
            PGID: 1000
            DEFAULT_WORKSPACE: /workspace
          ports:
            - "10.0.0.2:${toString config.port}:8443"
          volumes:
            - ./config:/config
            - /home/ubuntu/workspace:/workspace
          networks:
            - dev_network

      networks:
        dev_network:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "code-server-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
