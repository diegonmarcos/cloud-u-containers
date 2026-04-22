{
  description = "Radicale CalDAV/CardDAV — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-radicale.json);

    engine = import ../../_shared/engine.nix;

    svc = container.services;

    configVars = {
      APP_PORT        = toString buildJson.ports.app;
      MADDY_IP        = svc.maddy.ip;
      MADDY_IMAP_PORT = toString svc.maddy.ports.imap;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "config"; vars = configVars; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Radicale CalDAV/CardDAV";
      };
    });
  };
}
