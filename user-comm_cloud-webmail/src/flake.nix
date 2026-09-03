{
  description = "Cloud Webmail — native-JMAP webmail client for Stalwart (Type A own image, rebrand of root-fr/jmap-webmail)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    engine = import ../../_shared/engine.nix;
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson;
        # Engine only reads container.container.image (a Type-B fallback,
        # unused here). Passing {} keeps this flake self-contained — no
        # derive-generated src/build-<name>.json symlink required.
        container = {};
        srcDir = ./.;
        templates = [];
        # Type A — we own the build. Engine vendors this Dockerfile verbatim
        # into dist/code/arm64/Dockerfile and copies ./code/arm64/webapp (the
        # rebranded root-fr/jmap-webmail source) into the build context so the
        # multi-stage Next.js build has its sources.
        nativeBuild = {
          dockerfile = ./code/arm64/Dockerfile;
          extraFiles = [ ./code/arm64/webapp ];
        };
        composeSpec = import ./compose.nix { inherit buildJson; container = {}; };
        title = "Cloud Webmail";
      };
    });
  };
}
