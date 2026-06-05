{
  description = "Mattermost (team chat) + ntfy bridge + C3 bot — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON + ntfy-topics list) ──────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Primary container (mattermost itself) — engine wraps its image into
    # ghcr.io/diegonmarcos/<name>-binaries:latest (used by the mattermost
    # service in compose.nix).
    container = builtins.fromJSON (builtins.readFile ./build-mattermost.json);
    ntfyTopics = import ./ntfy-topics.nix;

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # base_domain derived from service domain: "chat.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix {
          inherit buildJson container base_domain ntfyTopics;
        };
        # ntfy-bridge.py + requirements are mounted from dist/assets/ by compose.
        # migrate-from-mattermost-bots.sh ships alongside them and is the
        # compose.pre_hook target — one-time migration of named volumes from
        # the old project's prefix (mattermost-bots_*) to the new one
        # (chat-mattermost_*) after the Stage 1 service-identity rename.
        # Marker-gated → no-op after first successful run.
        extraAssets = [
          ./code/ntfy-bridge.py
          ./code/requirements-bridge.txt
          ./code/migrate-from-mattermost-bots.sh
        ];
        # Type-A "service-shipped Dockerfile" — vendored Mattermost upstream
        # release-11.7/server/build/Dockerfile (see ./code/arm64/UPSTREAM.txt
        # for pin SHA + bump procedure). The build script reads
        # build.json#docker.build_args to set --build-arg MM_PACKAGE pointing
        # at the arm64 tarball at build time.
        nativeBuild = {
          dockerfile = ./code/arm64/Dockerfile;
          extraFiles = [ ./code/arm64/passwd ];
        };
        title = "Mattermost Team Chat (v2)";
      };
    });
  };
}
