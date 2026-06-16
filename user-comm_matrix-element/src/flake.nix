{
  description = "Element Web client for Continuwuity — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-matrix-element.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    base_domain = "diegonmarcos.com";

    vars = {
      HOMESERVER_URL  = "https://matrix.${base_domain}";
      SERVER_NAME     = base_domain;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "config.json"; inherit vars; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Element Web";
      };
    });
  };
}
