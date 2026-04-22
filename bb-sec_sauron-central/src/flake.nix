{
  description = "Sauron Central — Syslog collector + SIEM API — dist layout v2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    # build-sauron-central.json (symlink → 2_configs/dist/build-syslog-central.json)
    # tracks the service's canonical container record (cloud-data models
    # sauron-central as a single service). The local build.json owns the two
    # co-deployed containers (syslog-central + siem-api).
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-sauron-central.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "syslog-ng-central.conf"; vars = {}; }
          { name = "app.py";                 vars = {}; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Sauron Central";
      };
    });
  };
}
