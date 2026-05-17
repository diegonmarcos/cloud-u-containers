{
  description = "Stalwart Mail Server v0.13 — SHADOW MODE (JMAP/Sieve testing, offset ports) — dist layout v2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-stalwart.json);

    engine    = import ../../_shared/engine.nix;
    mailRulesLib = import ../../_shared/lib/mail-rules.nix;
    lib       = nixpkgs.lib;

    # Canonical mail rules (general + profile) → merged at build time.
    # Source of truth lives here (Stalwart owns); Maddy symlinks back in.
    mailRules = mailRulesLib { inherit lib; };
    merged    = mailRules.loadAndMerge {
      generalPath = ./mail-rules-general.json;
      profilePath = ./mail-rules-profile-diego.json;
    };
    sieveScript = mailRules.toSieve merged;
    legacyJson  = builtins.toJSON (mailRules.toLegacyJson merged);

    # base_domain derived from service domain: "jmap.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # Admin password hash (SHA-512 crypt) — generated from secrets, baked into config.
    # This is a HASH, not the plaintext password — safe to include in config.
    adminHash = "$6$StalwartShadow$TnGwCZsckFjb/S6BcJV5UL8Gxf25mlA4eO2WI1G7jDYCwdMTfeSQUAUcR2H6mujyRMTjAWMHf3SyRNW/3.r7a/";

    # Port comes from container spec (build.json#containers.app.port — the
    # HTTPS admin port Stalwart binds; same value surfaces via the
    # cloud-data derive pipeline into build-stalwart.json).
    appPort = toString buildJson.containers.app.port;

    # ── Template variable sets ──────────────────────────────────────
    configTomlVars = {
      DOMAIN     = buildJson.domain;
      APP_PORT   = appPort;
      ADMIN_HASH = adminHash;
    };

    # User creation block — generated from build.json#users (this service's SoT).
    # Each user becomes a Stalwart "individual" principal POSTed via the admin API.
    # Each role is mapped: admin→admin, all others→user. Aliases land in `emails`.
    mkUserLines = key: u:
      let
        addr   = "${u.name}@${base_domain}";
        emails = [ addr ] ++ (lib.optionals (u ? aliases) (map (a: "${a}@${base_domain}") u.aliases));
        emailsJson = "[" + lib.concatStringsSep "," (map (e: "\"${e}\"") emails) + "]";
        emailsJsonEsc = lib.replaceStrings ["\""] ["\\\""] emailsJson;
        role   = if key == "admin" then "admin" else "user";
        pwVar = (lib.toUpper key) + "_PW";
        # Shell-level var reference; rendered into the final script as $ADMIN_PW etc.
        pwRef = "$" + pwVar;
        passShell = "\"$" + u.pass_env + "\"";
      in lib.concatStringsSep "\n" [
        "${pwVar}=$(cat /opt/containers/stalwart/.secrets.d/${u.pass_env} 2>/dev/null || echo ${passShell})"
        "_post \"user ${addr}\" \"{\\\"type\\\":\\\"individual\\\",\\\"name\\\":\\\"${addr}\\\",\\\"secrets\\\":[\\\"${pwRef}\\\"],\\\"emails\\\":${emailsJsonEsc},\\\"roles\\\":[\\\"${role}\\\"]}\""
      ];

    userBlock = lib.concatStringsSep "\n\n" (lib.mapAttrsToList mkUserLines (buildJson.users or {}));

    # Bind IP for the admin API listener — activate.sh runs on the host (post-hook
    # via SSH), so it must hit the Docker-bound host IP, not localhost. Pull the
    # first bind from extra_ports[service==jmap_tls] in build.json.
    activateBindIp =
      let
        ports = buildJson.containers.app.extra_ports or [];
        jmap  = lib.findFirst (p: (p.service or "") == "jmap_tls") (builtins.head ports) ports;
        bind  = jmap.bind or "127.0.0.1";
      in if builtins.isList bind then builtins.head bind else bind;

    # ── Folder bootstrap — pulled from mail-rules-general.json ───────
    # folders_ui = parent containers, folders = leaf-name map (short → pretty).
    # Emit as `name|parent\n…` for the shell template. Parents first.
    mailRulesGeneral = builtins.fromJSON (builtins.readFile ./mail-rules-general.json);
    parentFolders    = mailRulesGeneral.folders_ui or [];
    leafFolders      = mailRulesGeneral.folders or {};

    # Each leaf's parent is the parent_ui whose first 2 chars match the leaf's
    # first 2 chars (e.g. "11    🛡️ Admin & Finance" → "10 _ ADMIN").
    findParent = leafName:
      let
        leafPrefix = builtins.substring 0 1 leafName;
        match = lib.findFirst (p: builtins.substring 0 1 p == leafPrefix) "" parentFolders;
      in match;

    leafLines = lib.mapAttrsToList (k: v: "${v}|${findParent v}") leafFolders;
    parentLines = map (p: "${p}|") parentFolders;
    foldersLines = lib.concatStringsSep "\n" (parentLines ++ leafLines);

    # User mailbox local-parts paired with their secret-env var name.
    # Format: "me=ME_PASSWORD no-reply=NOREPLY_PASSWORD" — the activate
    # script parses each pair to load the right password file.
    usersList = lib.concatStringsSep " " (
      map (u: "${u.name}=${u.pass_env}") (lib.attrValues (buildJson.users or {}))
    );

    activateShVars = {
      BASE_DOMAIN          = base_domain;
      APP_PORT             = appPort;
      BIND_IP              = activateBindIp;
      USER_CREATION_BLOCK  = userBlock;  # unused by new template, kept for back-compat
      USERS_LIST           = usersList;
      FOLDERS_LINES        = foldersLines;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      # Derived legacy JSON (what jmap-sorter.py reads at runtime).
      # Produced from canonical so there is exactly ONE source of truth.
      mailRulesDerived = pkgs.writeText "mail-rules.json" legacyJson;
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          # v0.14/v0.15 legacy main config (TOML). Kept during migration so a
          # rollback can re-mount it; v0.16 uses config.json below instead.
          { name = "config.toml";  vars = configTomlVars; }
          # v0.16+ data-store config (JSON). Everything else (listeners,
          # auth, sieve) lives as JMAP objects inside RocksDB and is seeded
          # via stalwart-cli apply during recovery-mode bootstrap.
          { name = "config.json";  vars = {}; }
          { name = "activate.sh";  vars = activateShVars; }
          # Sieve generated by _shared/lib/mail-rules.nix (shared with Maddy).
          { name = "default.sieve"; text = sieveScript; }
        ];
        # jmap-sorter.py + mail-rules.json bind-mounted from dist/assets/.
        # mail-rules.json is DERIVED from general + profile-diego canonicals.
        # The {name;src;} form is needed for derived assets so the dest
        # name is stable (otherwise baseNameOf would hash-prefix it).
        extraAssets = [
          ./code/jmap-sorter.py
          { name = "mail-rules.json"; src = mailRulesDerived; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain lib; };
        title = "Stalwart Mail Server (Shadow)";
      };
    });
  };
}
