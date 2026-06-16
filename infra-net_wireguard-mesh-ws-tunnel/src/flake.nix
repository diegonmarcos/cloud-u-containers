{
  description = "WireGuard Mesh — wstunnel-server (TCP/443 fallback transport for hostile networks)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-wireguard-mesh-ws-tunnel.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir      = ./.;
        templates   = [];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title       = "WireGuard Mesh — wstunnel server";
      };
    });
  };
}
