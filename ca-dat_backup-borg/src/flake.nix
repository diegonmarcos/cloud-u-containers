{
  description = "Borg Binary Backup Server (SSH receiver) — dist layout v2 (Type B, wrap upstream)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-borg-server.json);

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
            name = "entrypoint.sh";
            vars = {
              SSH_PORT       = toString buildJson.ports.app;
              # WG-bind from cloud-data — engine-resolved (resolveBindHost).
              LISTEN_ADDRESS = container.bind_host;
            };
          }
          { name = "authorized_keys";  vars = {}; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Borg Binary Backup Server";
      };
    });
  };
}
