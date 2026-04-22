{
  description = "Umami Analytics — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson      = builtins.fromJSON (builtins.readFile ../build.json);
    # Primary container (umami app) — engine wraps buildJson.upstream_image
    # into ghcr.io/diegonmarcos/<name>-binaries:latest.
    container      = builtins.fromJSON (builtins.readFile ./build-umami.json);
    containerDb    = builtins.fromJSON (builtins.readFile ./build-umami-db.json);
    containerSetup = builtins.fromJSON (builtins.readFile ./build-umami-setup.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # Service topology — WG IP for port binding comes from the app
    # container's services map (derived from cloud-data).
    svc = container.services;

    # buildJson.domain is "analytics.diegonmarcos.com/umami" — split on '/'
    # to get the hostname, then drop the first label to get base_domain.
    hostname    = lib.head (lib.splitString "/" buildJson.domain);
    base_domain = lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." hostname));

    # Template variables (pure strings, no shell escaping needed).
    setupVars = {
      PORT   = toString buildJson.ports.app;
      DOMAIN = buildJson.domain;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "setup.sh"; vars = setupVars; }
        ];
        composeSpec = import ./compose.nix {
          inherit buildJson container containerDb containerSetup svc;
        };
        extraAssets = [ ./migrate-from-matomo ];
        title = "Umami Analytics";
      };
    });
  };
}
