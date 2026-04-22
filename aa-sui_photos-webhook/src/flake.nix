{
  description = "Photos Webhook — PhotoPrism S3 processor + Postgres (v2, Type A own-code)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-photos-webhook.json);

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
        # schema.sql rides along as an asset — mounted by the db container
        # into /docker-entrypoint-initdb.d/ via the compose spec.
        extraAssets = [ ./schema.sql ];
        nativeBuild = {
          cmd       = nb.cmd;
          binary    = nb.entrypoint;   # ./entrypoint.sh — engine basenames this
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = buildJson.description;
      };
    });
  };
}
