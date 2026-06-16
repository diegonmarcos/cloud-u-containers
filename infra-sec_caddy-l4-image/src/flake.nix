{
  description = "Custom Caddy image (L4 + ratelimit + cloudflare-dns) — dist layout v2 (Type B, wrap upstream)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-caddy-l4-image.json);

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
        # Type B wrap — engine emits dist/code/<arch>/Dockerfile as thin
        # FROM caddy:2 stub (validator-compliant). The real xcaddy build
        # recipe lives in src/code/Dockerfile and is consumed by the ship
        # engine's step_docker via build.json#docker.dockerfile.
        title = "Custom Caddy Image (L4 + plugins)";
      };
    });
  };
}
