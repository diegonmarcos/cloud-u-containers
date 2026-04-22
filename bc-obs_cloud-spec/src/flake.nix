{
  description = "Unified Cloud Documentation Portal — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-cloud-spec.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      # Build the mdbook documentation site as a Nix derivation.
      site = pkgs.runCommand "cloud-spec-site" {
        nativeBuildInputs = [ pkgs.mdbook ];
      } ''
        mkdir -p build/src
        cp -r ${./docs}/* build/src/
        cp ${./book.toml} build/book.toml
        cd build && mdbook build -d $out
      '';

      # Engine output (manifest.json, compose/, code/, configs/, assets/).
      baseDist = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = buildJson.description;
      };

    in {
      # Wrap engine output, overlaying the built mdbook site at assets/site/
      # so compose.nix can mount ./assets/site:/srv:ro.
      default = pkgs.runCommand "${buildJson.name}-dist-v2" {
        passthru = { inherit (baseDist.passthru) manifest declaredArchs; };
      } ''
        mkdir -p $out
        cp -r ${baseDist}/. $out/
        chmod -R u+w $out
        mkdir -p $out/assets/site
        # mdbook emits into site root; if an 'html/' subdir exists (older
        # mdbook versions), flatten it — otherwise copy contents verbatim.
        if [ -d ${site}/html ]; then
          cp -r ${site}/html/. $out/assets/site/
        else
          cp -r ${site}/. $out/assets/site/
        fi
      '';
    });
  };
}
