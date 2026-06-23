{
  description = "CF-Worker → wg-public Bridge — dist layout v2 (Type A, own code). Mirror of http-to-smtp-proxy-api on the wg-public mesh (oci-analytics ingress).";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-cf-worker-http-to-wg-public-bridge.json);

    engine = import ../../_shared/engine.nix;
    nb = buildJson.docker.native_build;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        nativeBuild = {
          cmd       = nb.cmd;
          binary    = nb.binary;
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = "CF-Worker → wg-public Bridge (v2)";
      };
    });
  };
}
