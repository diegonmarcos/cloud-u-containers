{
  description = "caddy-l4-public — public-edge SNI-mux on oci-analytics, TCP-relay *.diegonmarcos.com → gcp-proxy:443 over wg-public";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Per-service derive output is emitted by 2_configs gen-configs once this
    # service is declared in build.json. Falls back to a minimal stub so the
    # flake evaluates on first deploy (before gen-configs has run).
    containerFile = ./build-caddy-l4-public.json;
    container =
      if builtins.pathExists containerFile
      then builtins.fromJSON (builtins.readFile containerFile)
      else { services = {}; };

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        # No templates — Caddyfile is a static literal (literally one route).
        templates = [];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        # Type B: wrap upstream image (ghcr.io/diegonmarcos/caddy-l4).
        # No nativeBuild block — engine produces compose + configs only.
        title = buildJson.description;
      };
    });
  };
}
