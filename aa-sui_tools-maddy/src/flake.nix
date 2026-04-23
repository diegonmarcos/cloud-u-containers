{
  description = "Maddy Mail Server — declarative all-in-one SMTP/IMAP (dist layout v2, flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-maddy.json);

    engine       = import ../../_shared/engine.nix;
    mailRulesLib = import ../../_shared/lib/mail-rules.nix;
    lib          = nixpkgs.lib;

    # Canonical mail rules — sole source of truth lives in Stalwart's src/;
    # Maddy symlinks them in. Both services derive their runtime outputs
    # from the same two JSONs via the shared _shared/lib/mail-rules.nix.
    mailRules = mailRulesLib { inherit lib; };
    merged    = mailRules.loadAndMerge {
      generalPath = ./mail-rules-general.json;          # symlink → stalwart canonical
      profilePath = ./mail-rules-profile-diego.json;    # symlink → stalwart canonical
    };
    maddyRulesJson = builtins.toJSON (mailRules.toMaddyJson merged);

    # base_domain derived from service domain: "mail.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # Per-port bind addresses: reads extra_ports[].bind from build.json and
    # generates BIND_465, BIND_587, BIND_993, BIND_143 etc. for template substitution.
    # Fallback to 0.0.0.0 if a port has no bind (backward-compatible).
    bindVars = builtins.listToAttrs (
      map (ep: { name = "BIND_${toString ep.port}"; value = ep.bind or "0.0.0.0"; })
          (buildJson.containers.app.extra_ports or [])
    );

    maddyConfVars = bindVars // {
      DOMAIN         = base_domain;
      MAIL_DOMAIN    = buildJson.domain;
      OCI_RELAY_HOST = buildJson.oci_relay.host;
      OCI_RELAY_PORT = buildJson.oci_relay.port;
    };

    initShVars = {
      BASE_DOMAIN = base_domain;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      # Derived Maddy subset — consumed by mail-filter.sh at /data/mail-rules.json.
      # Keeping filename stable means compose volume mounts need no change.
      mailRulesDerived = pkgs.writeText "mail-rules.json" maddyRulesJson;
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init.sh";       vars = initShVars; }
          { name = "maddy.conf.tpl"; vars = maddyConfVars; }
        ];
        # mail-filter.sh / mail-rules.json bind-mounted from dist/assets/.
        # mail-rules.json is DERIVED (Maddy subset) via _shared/lib/mail-rules.nix.
        # cleanup-stale-mailboxes.sh + dedupe-inbox.sh run via lifecycle.ssh_run
        # on the VM host (see build.json#lifecycle).
        extraAssets = [
          ./mail-filter.sh
          { name = "mail-rules.json"; src = mailRulesDerived; }
          ./cleanup-stale-mailboxes.sh
          ./dedupe-inbox.sh
          ./dedupe-folders.sh
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Maddy Mail Server";
      };
    });
  };
}
