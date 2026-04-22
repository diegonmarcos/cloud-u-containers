{
  description = "SnappyMail — Lightweight webmail client for Maddy (dist layout v2, flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-snappymail.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # base_domain derived from service domain: "webmail.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    mail_domain = "mail.${base_domain}";

    appConfigVars    = { BASE_DOMAIN = base_domain; };
    domainConfigVars = { MAIL_DOMAIN = mail_domain; };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init.sh";                             vars = {}; }
          { name = "application.ini";                     vars = appConfigVars; }
          { name = "domain.ini";                          vars = domainConfigVars; }
          { name = "live.com.ini";                        vars = {}; }
          { name = "gmail.com.ini";                       vars = {}; }
          { name = "mail-stalwart.diegonmarcos.com.ini";  vars = {}; }
        ];
        # Pre-seed data + PHP executor for SnappyMail's additional accounts.
        # Mounted into the container by compose.nix; invoked by init.sh at
        # container start.
        extraAssets = [
          ./seed-accounts.json
          ./seed-accounts.php
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "SnappyMail Webmail";
      };
    });
  };
}
