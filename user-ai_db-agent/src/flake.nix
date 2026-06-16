{
  description = "db-agent — central DB backup agent (all VMs) — dist layout v2 (Type A, own code)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-db-agent.json);

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
          # Not a compiled binary — ENTRYPOINT is the baked entrypoint.sh.
          # Engine's Type A Dockerfile stub uses baseNameOf(binary) only as a
          # label; the real build is done by ship-engine via image-wrapper.
          binary    = nb.entrypoint;
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = "db-agent — Central DB Backup Agent (v2)";
      };
    });
  };
}
