{
  description = "agents-tmp-reaper — periodic scrub of agent /tmp on oci-apps (task 442) — dist layout v2 (Type A, own code)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-agents-tmp-reaper.json);

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
        # Type A own-code image-wrapper: the baked entrypoint.sh is the whole
        # binary, and the base image ships bash + docker-cli. No compiled code.
        nativeBuild = {
          cmd       = nb.cmd;
          binary    = nb.entrypoint;
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = "agents-tmp-reaper — agent /tmp scrub (task 442)";
      };
    });
  };
}