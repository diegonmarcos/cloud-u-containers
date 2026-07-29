{
  description = "my-ai-api — polyglot OpenRouter proxy with Headroom compression and plugin pipeline";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container  = builtins.fromJSON (builtins.readFile ./build-my-ai-api.json);

    engine = import ../../_shared/engine.nix;
    nb     = buildJson.docker.native_build;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir      = ./.;
        templates   = [];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        nativeBuild = {
          dockerfile = ./code/Dockerfile;
          extraFiles = [
            ./code/vendor
            ./code/py
            ./code/server.mjs
            ./code/gateway.mjs
            ./code/package.json
            ./code/start.sh
            ./code/principles
            ./code/configs
          ];
          cmd       = nb.cmd or "";
          binary    = nb.entrypoint or "";
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = "my-ai-api";
      };
    });
  };
}
