{
  description = "Bup — Git-based backup server for database dumps (SSH receiver) — dist layout v2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-bup-server.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          {
            name = "init.sh";
            vars = {
              SSH_PORT       = toString buildJson.ports.app;
              # WG-bind from cloud-data — engine-resolved (resolveBindHost).
              LISTEN_ADDRESS = container.bind_host;
            };
          }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        extraAssets = [ ./authorized_keys ];
        title = "Bup Backup Server (SSH receiver)";
      };
    });
  };
}
