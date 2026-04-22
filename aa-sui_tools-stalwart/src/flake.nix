{
  description = "Stalwart Mail Server v0.13 — SHADOW MODE (JMAP/Sieve testing, offset ports) — dist layout v2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-stalwart.json);
    mailRules = builtins.fromJSON (builtins.readFile ./mail-rules.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # base_domain derived from service domain: "mail-stalwart.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # Admin password hash (SHA-512 crypt) — generated from secrets, baked into config.
    # This is a HASH, not the plaintext password — safe to include in config.
    adminHash = "$6$StalwartShadow$TnGwCZsckFjb/S6BcJV5UL8Gxf25mlA4eO2WI1G7jDYCwdMTfeSQUAUcR2H6mujyRMTjAWMHf3SyRNW/3.r7a/";

    # Port comes from container spec (build.json#containers.app.port — the
    # HTTPS admin port Stalwart binds; same value surfaces via the
    # cloud-data derive pipeline into build-stalwart.json).
    appPort = toString buildJson.containers.app.port;

    # ── Sieve generation (pure Nix dispatch on rule.type) ───────────
    mkCondition = rule:
      if rule.type == "from_domain" then
        let domains = lib.concatMapStringsSep ", " (d: ''"${d}"'') rule.values;
        in ''address :domain "From" [${domains}]''
      else if rule.type == "from_address" then
        let addrs = lib.concatMapStringsSep ", " (a: ''"${a}"'') rule.values;
        in ''address :is "From" [${addrs}]''
      else if rule.type == "header_contains" then
        let vals = lib.concatMapStringsSep ", " (v: ''"${v}"'') rule.values;
        in ''header :contains "${rule.header}" [${vals}]''
      else if rule.type == "header_exists" then
        ''exists "${rule.header}"''
      else if rule.type == "size_over" then
        "size :over ${toString rule.bytes}"
      else if rule.type == "self_sent" then
        ''address :is "From" "${mailRules.account}"''
      else if rule.type == "has_cc" then
        ''exists "CC"''
      else if rule.type == "list_header" then
        ''exists "List-Unsubscribe"''
      else if rule.type == "content_type" then
        ''header :mime :anychild :contenttype "Content-Type" "${rule.value}"''
      else
        "false";

    # Tag line: if <condition> { addflag + fileinto numbered subfolder }
    mkTagLine = group: rule:
      let
        idx      = toString (lib.lists.findFirstIndex (r: r == rule) 0 group.rules);
        groupNum = builtins.head (lib.strings.splitString "-" group.name);
        subFolder = "${group.name}/${groupNum}-${idx} ${rule.flag}";
      in
      ''if ${mkCondition rule} { addflag "${rule.flag}"; fileinto :copy :create "${subFolder}"; }'';

    # Tag group: comment header + all rules
    mkTagGroup = group:
      "# -- ${group.id}: ${group.name} --\n"
      + lib.concatStringsSep "\n" (map (mkTagLine group) group.rules);

    # Routing rule: if <condition> { fileinto :create "<folder>"; stop; }
    mkRoutingRule = route:
      "if ${mkCondition route.match} {\n  fileinto :create \"${route.folder}\";\n  stop;\n}";

    # Full Sieve script assembly
    sieveScript =
      let
        requires       = lib.concatMapStringsSep ", " (e: ''"${e}"'') mailRules.sieve_require;
        tagSection     = lib.concatStringsSep "\n\n" (map mkTagGroup mailRules.tags);
        routingSection = lib.concatStringsSep "\n" (map mkRoutingRule mailRules.routing);
      in ''
        require [${requires}];

        # ══════════════════════════════════════════════════════════════════
        # TAGS — all matching rules fire (additive IMAP keywords)
        # Generated from mail-rules.json — DO NOT EDIT
        # ══════════════════════════════════════════════════════════════════

        ${tagSection}

        # ══════════════════════════════════════════════════════════════════
        # ROUTING — first match wins (fileinto + stop)
        # ══════════════════════════════════════════════════════════════════

        ${routingSection}
        # Default: unmatched emails go to Others
        fileinto :create "${mailRules.routing_default}";
      '';

    # ── Template variable sets ──────────────────────────────────────
    configTomlVars = {
      DOMAIN     = buildJson.domain;
      APP_PORT   = appPort;
      ADMIN_HASH = adminHash;
    };

    activateShVars = {
      BASE_DOMAIN = base_domain;
      APP_PORT    = appPort;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "config.toml";  vars = configTomlVars; }
          { name = "activate.sh";  vars = activateShVars; }
          # Sieve generated from mail-rules.json via pure-Nix dispatch (not a .tpl).
          { name = "default.sieve"; text = sieveScript; }
        ];
        # jmap-sorter.py + mail-rules.json bind-mounted from dist/assets/.
        # jmap-sorter.py lives under src/code/ per v2 layout (no source at src/ root).
        extraAssets = [
          ./code/jmap-sorter.py
          ./mail-rules.json
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Stalwart Mail Server (Shadow)";
      };
    });
  };
}
