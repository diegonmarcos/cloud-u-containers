{
  description = "jev-sidecar — the oci-apps Jev decisions sidecar (#881): `jev-gate serve` on the mesh";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-jev-sidecar.json);

    engine = import ../../_shared/engine.nix;

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
          # Service-vendored Dockerfile, copied verbatim to dist/code/<arch>/Dockerfile.
          dockerfile = ./code/Dockerfile;
          # The ONE Jev gate (#764), staged by basename so the Dockerfile COPYs it as jev-gate/.
          extraFiles = [ ../../_shared/jev-gate ];
          cmd       = "";
          binary    = "";
          baseImage = buildJson.upstream_image;
          apt       = "";
        };
        title = "jev-sidecar";
      };
    });
  };
}
