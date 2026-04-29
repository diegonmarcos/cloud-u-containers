{
  description = "Cypht webmail — multi-account IMAP/JMAP/SMTP/RSS/calendar (dist layout v2, flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-cypht.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # base_domain derived from service domain: "webmail.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # mail.${base_domain} resolves to 127.0.0.1 on oci-mail (via /etc/hosts)
    # → Maddy's loopback bind handles IMAPS/SMTPS for the primary account.
    # Same routing approach as snappymail (already proven working).
    mail_domain = "mail.${base_domain}";

    # Stalwart hostname for the JMAP + IMAP secondary backend.
    # External clients hit this via Caddy L4 forwarders on gcp-proxy:2443/2993/2465.
    # On oci-mail (host network), it resolves through the same Caddy chain.
    stalwart_domain = "mail-stalwart.${base_domain}";

    # WG IP for oci-mail (where cypht runs). Binding nginx here enforces
    # WG-only access at the socket level — same pattern as Maddy/Stalwart.
    wg_ip = "10.0.0.3";

    # Template substitution vars (build-time, @VAR@ syntax).
    cyphtEnvVars = {
      BASE_DOMAIN          = base_domain;
      MAIL_DOMAIN          = mail_domain;
      STALWART_DOMAIN      = stalwart_domain;
      STALWART_IMAP_PORT   = "2993";
      STALWART_JMAP_PORT   = "2443";
      STALWART_SMTP_PORT   = "2465";
      CYPHT_PORT           = toString buildJson.ports.app;
      POSTGRES_HOST        = "127.0.0.1";
      POSTGRES_PORT        = "5432";
      POSTGRES_DB          = "cypht";
      POSTGRES_USER        = "cypht";
    };

    nginxConfVars = {
      WG_IP      = wg_ip;
      CYPHT_PORT = toString buildJson.ports.app;
    };

    # Seed-accounts SQL template uses no @VAR@ (it's read at runtime by the
    # seeder, which substitutes per-account values in shell).
    sqlVars = {};

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init.sh";              vars = {}; }
          { name = "cypht.env";            vars = cyphtEnvVars; }
          { name = "nginx.conf";           vars = nginxConfVars; }
          { name = "php-fpm-www.conf";     vars = {}; }
          { name = "seed-accounts.sql";    vars = sqlVars; }
        ];
        # Account inventory + idempotent psql seeder.
        # Mounted into the container by compose.nix; invoked by entrypoint
        # at container start (after cypht-postgres is healthy).
        extraAssets = [
          ./seed-accounts.json
          ./seed-accounts.sh
          ./seed-accounts.php
          ./seed-config.json
          # ntfy topics: copied from canonical I_cloud-data/ntfy-api/src/topics.json
          # at build.sh pre-flake time (nix pure-eval can't reach across submodule
          # boundaries via symlink). The copy is regenerated from the source whenever
          # build.sh runs, so the canonical file remains the SoT.
          ./ntfy-topics.json
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Cypht Webmail";
      };
    });
  };
}
