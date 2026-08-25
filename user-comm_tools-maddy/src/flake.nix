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

    # F0 sender-classification folders (Fa..Fk, Fz) -- the ONLY category
    # folders Maddy routes into now (see toMaddyJson). Unlike Stalwart,
    # nothing here auto-creates a target mailbox: apply-rules' SQL-direct
    # COPY only UPDATEs an existing mboxes row, it never INSERTs one, so
    # these must exist before the first apply-rules run or every copy into
    # them silently no-ops. `maddy imap-mboxes create` is idempotent enough
    # for a boot-time init.sh (errors on a folder that already exists;
    # piped to /dev/null + `|| true` like every other create call here).
    senderFolders = map (v: v.folder)
      (lib.filter (v: (v.axis or null) == "sender") (merged.filters.views or []));

    # base_domain derived from service domain: "mail.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # Per-port listener prefixes: reads extra_ports[].bind from build.json and
    # generates LISTEN_25, LISTEN_465, LISTEN_993, LISTEN_143 etc. for template
    # substitution. Each LISTEN_<port> expands to a SCHEME://IP:PORT line — or
    # space-separated multi-listener line when bind is a list (Phase 4 dual-bind
    # on wg0 + wg-public, e.g. `tls://10.0.0.3:993 tls://10.1.0.3:993`).
    # Backward compat: bind as string still works (single entry).
    schemeFor = ep:
      if (ep.protocol or "") == "tls" then "tls://" else "tcp://";
    bindIpsFor = ep:
      let raw = ep.bind or "0.0.0.0"; in
      if builtins.isList raw then raw else [ raw ];
    listenLineFor = ep:
      let
        scheme = schemeFor ep;
        port   = toString ep.port;
        ips    = bindIpsFor ep;
      in lib.concatStringsSep " " (map (ip: "${scheme}${ip}:${port}") ips);
    bindVars = builtins.listToAttrs (
      map (ep: { name = "LISTEN_${toString ep.port}"; value = listenLineFor ep; })
          (buildJson.containers.app.extra_ports or [])
    );

    maddyConfVars = bindVars // {
      DOMAIN         = base_domain;
      MAIL_DOMAIN    = buildJson.domain;
      OCI_RELAY_HOST = buildJson.oci_relay.host;
      OCI_RELAY_PORT = buildJson.oci_relay.port;
    };

    # User creation block — generated from build.json#users (this service's SoT).
    # Each user gets creds create + creds password (UPSERT) + imap-acct create.
    # Use -p flag (not pipe) — maddy creds password tries TurnOnRawIO on stdin
    # even when piped, which fails without a TTY (inappropriate ioctl for device).
    # Shell-level $ENV refs are built via string concat to avoid Nix interpolation
    # confusion with multi-line `''...''` strings.
    mkUserLines = key: u:
      let
        addr      = "${u.name}@${base_domain}";
        passShell = "\"$" + u.pass_env + "\"";
      in lib.concatStringsSep "\n" [
        "maddy creds create   -p ${passShell} ${addr} 2>&1 | sed 's|^|  [creds:create ${u.name}]   |' || true"
        "maddy creds password -p ${passShell} ${addr} 2>&1 | sed 's|^|  [creds:password ${u.name}] |' || true"
        "maddy imap-acct create ${addr} 2>/dev/null || true"
      ];

    userBlock = lib.concatStringsSep "\n" (lib.mapAttrsToList mkUserLines (buildJson.users or {}));

    mkFolderLines = key: u:
      let addr = "${u.name}@${base_domain}";
      in lib.concatMapStringsSep "\n"
        (f: "maddy imap-mboxes create ${addr} '${f}' 2>&1 | sed 's|^|  [mboxes:create ${u.name}]   |' || true")
        senderFolders;

    folderBlock = lib.concatStringsSep "\n" (lib.mapAttrsToList mkFolderLines (buildJson.users or {}));

    initShVars = {
      BASE_DOMAIN          = base_domain;
      USER_CREATION_BLOCK  = userBlock;
      FOLDER_CREATION_BLOCK = folderBlock;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      # Derived Maddy subset — consumed by mail-sieve-subset-delivery-time.sh at /data/mail-rules.json.
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
        # Two scripts only:
        #   mail-sieve-subset-delivery-time.sh — per-message at delivery (jq)
        #   mail-sieve-subset-post-hoc.sh      — batch maintenance (sqlite + jq)
        # Both consume /data/mail-rules.json (derived Maddy subset of canonical
        # rules via _shared/lib/mail-rules.nix → toMaddyJson; same SoT also
        # renders Stalwart's default.sieve).
        # The retired pre-SQL scripts live in src/z-archive/ for the transition
        # period — NOT bundled here, NOT mounted into the container, NOT
        # referenced by build.json#lifecycle. Will be deleted in a follow-up
        # commit after Phase 4 prod migration + 30-day soak (see z-archive/README.md).
        extraAssets = [
          ./mail-sieve-subset-delivery-time.sh
          ./mail-sieve-subset-post-hoc.sh
          { name = "mail-rules.json"; src = mailRulesDerived; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Maddy Mail Server";
      };
    });
  };
}
