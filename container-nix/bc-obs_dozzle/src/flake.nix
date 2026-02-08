{
  description = "Dozzle - Real-time Docker log viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "dozzle";
      image = "amir20/dozzle:latest";
      port = 9999;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        dozzle:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:8080"
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
          environment:
            - DOZZLE_LEVEL=info
            - DOZZLE_TAILSIZE=300
          mem_limit: 64m
          networks:
            - npm_default

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "dozzle-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
