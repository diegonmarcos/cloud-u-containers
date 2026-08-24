{
  description = "C3 MCP Server — Cloud Control Center MCP transport (stdio + HTTP) — dist layout v2 (Type A, own code)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-cloud-infra-mcp.json (symlink → 1_cicd/dist/).
    # Engine resolves symlink before nix build.
    container = builtins.fromJSON (builtins.readFile ./build-cloud-infra-mcp.json);

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
          binary    = nb.entrypoint or "";
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = buildJson.description;
      };
    });
  };
}
