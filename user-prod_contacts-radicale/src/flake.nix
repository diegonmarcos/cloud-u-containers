{
  description = "Radicale CardDAV (contacts only) — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-contacts-radicale.json);

    engine = import ../../_shared/engine.nix;

    svc = container.services;

    # IMAP auth goes to Stalwart (the live IMAPS store since the 2026-09-02
    # migration), not maddy. Port is looked up by its declared service label in
    # stalwart's extra_ports, so a renumbered listener follows its declaration.
    stalwartImapPort = builtins.head (builtins.attrNames
      (nixpkgs.lib.filterAttrs (_: ep: (ep.service or "") == "imap_ssl") svc.stalwart.extra_ports));

    configVars = {
      APP_PORT        = toString buildJson.ports.app;
      IMAP_HOST       = svc.stalwart.ip;
      IMAP_PORT       = stalwartImapPort;
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
        title = "Radicale CardDAV (Contacts)";
      };
    });
  };
}
