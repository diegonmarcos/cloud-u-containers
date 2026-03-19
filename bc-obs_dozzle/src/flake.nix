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

    title = "Dozzle - Real-time Docker log viewer";
    docker = import ../../_shared/docker.nix;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_dozzle/src/flake.nix";
      services = {
        dozzle = docker.mkService {
          name = "dozzle";
          image = config.image;
          container_name = config.container_name;
          ports = ["10.0.0.4:${toString config.port}:8080"];
          volumes = ["/var/run/docker.sock:/var/run/docker.sock:ro"];
          environment = ["DOZZLE_LEVEL=info"];
          memLimit = "64m";
          networks = ["npm_default"];
          skipReadOnly = true;
          skipSecurity = true;
        };
      };
      networks = {
        npm_default = { external = true; };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "dozzle-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
