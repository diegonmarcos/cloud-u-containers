{
  description = "Authelia 2FA — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson   = builtins.fromJSON (builtins.readFile ../build.json);
    container   = builtins.fromJSON (builtins.readFile ./build-authelia.json);
    oidcClients = (builtins.fromJSON (builtins.readFile ./oidc-clients.json)).clients;

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    svc = container.services;

    subst = s: lib.replaceStrings [ "@BASE_DOMAIN@" ] [ base_domain ] s;

    # ── ACL rules from container.acl.rules (data-driven) ───────────
    autheliaAcl =
      if (container.acl.rules or []) == []
      then [{ domain = "*.${base_domain}"; policy = "two_factor"; service = "_default"; }]
      else container.acl.rules;

    i4 = "    "; i6 = "      "; i8 = "        ";
    mkResourceLines = rs:
      lib.concatMapStringsSep "\n" (r: "${i8}- \"${r}\"") rs;
    mkRuleYaml = rule: let
      hasBypass    = rule ? resources_bypass     && rule.resources_bypass     != [];
      hasTwoFactor = rule ? resources_two_factor && rule.resources_two_factor != [];
      plain = if !hasBypass && !hasTwoFactor
        then "${i4}- domain: '${rule.domain}'\n${i6}policy: ${rule.policy}" else "";
      bypass = if hasBypass
        then "${i4}- domain: '${rule.domain}'\n${i6}resources:\n${mkResourceLines rule.resources_bypass}\n${i6}policy: bypass" else "";
      twoFactor = if hasTwoFactor
        then "${i4}- domain: '${rule.domain}'\n${i6}resources:\n${mkResourceLines rule.resources_two_factor}\n${i6}policy: two_factor" else "";
      parts = builtins.filter (s: s != "") [ bypass twoFactor plain ];
    in lib.concatStringsSep "\n" parts;
    accessControlYaml = lib.concatMapStringsSep "\n" mkRuleYaml autheliaAcl;

    # ── OIDC clients YAML generator (data-driven from oidc-clients.json) ──
    i12 = "            "; i14 = "              ";
    optLine = k: v: if v == null then "" else "${i12}${k}: ${toString v}\n";
    optBool = k: v: if v == null then "" else "${i12}${k}: ${if v then "true" else "false"}\n";
    optList = k: vs:
      if vs == null || vs == [] then "" else
      "${i12}${k}:\n" + lib.concatMapStrings (v: "${i14}- ${v}\n") vs;

    mkClientYaml = c:
      "          - client_id: ${c.client_id}\n"
      + "${i12}client_secret: '{{ secret \"/tmp/.secrets.d/${c.secret_var}\" }}'\n"
      + optLine "consent_mode"          (c.consent_mode          or null)
      + optLine "client_name"           (c.client_name           or null)
      + optBool "public"                (c.public                or null)
      + optLine "authorization_policy"  (c.authorization_policy  or null)
      + optList "redirect_uris"         (if c ? redirect_uris then map subst c.redirect_uris else null)
      + optList "grant_types"           (c.grant_types           or null)
      + optList "response_types"        (c.response_types        or null)
      + optList "response_modes"        (c.response_modes        or null)
      + optList "scopes"                (c.scopes                or null)
      + optLine "userinfo_signed_response_alg" (c.userinfo_signed_response_alg or null)
      + optLine "token_endpoint_auth_method"   (c.token_endpoint_auth_method   or null)
      + optBool "require_pushed_authorization_requests" (c.require_pushed_authorization_requests or null)
      + optBool "require_pkce"          (c.require_pkce          or null)
      + optLine "pkce_challenge_method" (c.pkce_challenge_method or null)
      + optLine "access_token_signed_response_alg" (c.access_token_signed_response_alg or null)
      + optList "audience"              (if c ? audience then map subst c.audience else null);

    oidcClientsYaml = lib.concatMapStringsSep "\n" mkClientYaml oidcClients;

    configurationVars = {
      DOMAIN               = buildJson.domain;
      BASE_DOMAIN          = base_domain;
      REDIS_PORT           = toString buildJson.ports.redis;
      MADDY_IP             = svc.maddy.ip;
      MADDY_SMTP_PORT      = toString svc.maddy.ports.smtp;
      ACCESS_CONTROL_RULES = accessControlYaml;
      OIDC_CLIENTS         = oidcClientsYaml;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init.sh";           vars = { BASE_DOMAIN = base_domain; }; }
          { name = "configuration.yml"; vars = configurationVars; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Authelia 2FA";
      };
    });
  };
}
