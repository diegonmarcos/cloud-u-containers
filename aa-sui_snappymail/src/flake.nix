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

    # `mail.${base_domain}` matches Maddy's TLS cert and is the public name.
    # On oci-mail (where snappymail runs network_mode: host), /etc/hosts
    # overrides it to 127.0.0.1 so the connection stays loopback — Maddy now
    # binds *both* 10.0.0.3 and 127.0.0.1 (see maddy.conf.tpl.tpl). External
    # clients hit the public hostname → Caddy L4 :993 → 10.0.0.3.
    # NOTE: .app names cannot be used here. They route on Caddy :443 only
    # (HTTPS reverse_proxy); Caddy L4 :993 is port-based, not hostname-based.
    # Plus .app is a real public TLD — Cloudflare returns spurious AAAA that
    # PHP picks before the Hickory A record, breaking IPv4-only paths.
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
