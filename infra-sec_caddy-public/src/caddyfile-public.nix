# ══════════════════════════════════════════════════════════════════
# caddyfile-public.nix — public-edge L7 allowlist generator
#
# Renders the Caddyfile for the caddy-public service on oci-analytics.
# DATA-DRIVEN: reads build-caddy-public.json (symlink → 2_configs/dist/)
# and emits ONLY the declared-public allowlist at the edge; EVERYTHING
# else forwards to gcp-proxy over wg-public (private_forward_upstream).
#
# Pure-syntax fragments live as `.caddy.tpl` files in `./snippets/`;
# this file only does orchestration: read → substitute @PLACEHOLDER@ →
# assemble — mirroring infra-sec_caddy/src/caddyfile.nix.
#
# Fail-closed posture (security invariant):
#   · ONLY auth=="none" subdomains, gh-pages, well-known, and explicitly
#     declared `public_paths` are served with a REAL upstream at the edge.
#   · base_path itself, authed subdomains, wg_only routes, and any host or
#     path not explicitly handled → forwarded to gcp-proxy, whose @wg gate
#     (remote_ip 10.0.0.0/24) 403s the public client. NEVER served here.
#   · EVERY forward/fallback target == caddyPublic.private_forward_upstream
#     (10.1.0.2:443). NEVER a wg0 (10.0.0.x) address for the fallback.
# ══════════════════════════════════════════════════════════════════
{ lib, caddyPublic }:

let
  # ── Snippet loader: read .caddy.tpl + apply @KEY@ substitutions ──
  readTpl = name: builtins.readFile (./snippets + "/${name}");
  subst = subs: text:
    lib.replaceStrings (lib.attrNames subs) (lib.attrValues subs) text;
  stripTrail = s: lib.removeSuffix "\n" s;

  # ── Critical fail-closed target: gcp-proxy over wg-public ──
  privateUpstream = caddyPublic.private_forward_upstream;

  # Forward helper — every non-allowlisted host/path lands here.
  fwd = "reverse_proxy ${privateUpstream}";

  # Real-client IP carry-over for any reverse_proxy that serves a real
  # upstream at the edge (mirrors caddyfile.nix's header_up usage).
  xreal = "header_up X-Real-IP {http.request.remote.host}";

  # ── Security snippets (data-driven from caddyPublic.security_snippets) ──
  ss = caddyPublic.security_snippets or {};

  securityHeaders = let h = ss.security_headers; in
    subst {
      "@HSTS_MAX_AGE@"       = toString h.hsts_max_age;
      "@FRAME_OPTIONS@"      = h.frame_options;
      "@REFERRER_POLICY@"    = h.referrer_policy;
      "@PERMISSIONS_POLICY@" = h.permissions_policy;
      "@CORS_ORIGIN@"        = h.cors_origin;
      "@CORS_METHODS@"       = h.cors_methods;
      "@CORS_HEADERS@"       = h.cors_headers;
      "@HIDE_HEADERS@"       = lib.concatMapStringsSep "\n        " (x: "-${x}") (h.hide_headers or []);
    } (readTpl "10-security-headers.caddy.tpl");

  rateLimiting = let r = ss.rate_limit; in
    subst {
      "@RL_ZONE@"   = r.zone;
      "@RL_KEY@"    = r.key;
      "@RL_EVENTS@" = toString r.events;
      "@RL_WINDOW@" = r.window;
    } (readTpl "11-rate-limiting.caddy.tpl");

  blockBots = let uas = lib.concatStringsSep "|" ss.bot_blocker.user_agents; in
    subst { "@BOT_UAS@" = uas; } (readTpl "12-block-bots.caddy.tpl");

  blockScanners = let paths = lib.concatStringsSep " " ss.scanner_blocker.paths; in
    subst { "@SCANNER_PATHS@" = paths; } (readTpl "13-block-scanners.caddy.tpl");

  requestLimits = let r = ss.request_limits; in
    subst { "@REQ_MAX_BODY@" = r.max_body; } (readTpl "14-request-limits.caddy.tpl");

  ipBlock = let
    cidrs = ss.ip_block.cidrs or [];
    body = if cidrs == []
      then "# no blocked CIDRs"
      else ''@blocked_ips remote_ip ${lib.concatStringsSep " " cidrs}
    respond @blocked_ips 403'';
  in subst { "@IP_BLOCK_BODY@" = body; } (readTpl "15-ip-block.caddy.tpl");

  accessLog = let a = ss.access_log; in
    subst {
      "@LOG_PATH@"      = a.path;
      "@LOG_ROLL_SIZE@" = a.roll_size;
      "@LOG_ROLL_KEEP@" = toString a.roll_keep;
      "@LOG_FORMAT@"    = a.format;
    } (readTpl "16-access-log.caddy.tpl");

  securitySnippet = readTpl "17-security-snippet.caddy.tpl";

  # `sec` imported inline at the top of every served site block.
  sec = ''  import security'';

  # ── Error handler (snippet-driven from caddyPublic.error_handler) ──
  eh = caddyPublic.error_handler or { status_codes = [ 502 503 504 ]; error_html = "/srv/error.html"; };
  codesExpr = lib.concatMapStringsSep " || " (c: "{err.status_code} == ${toString c}") eh.status_codes;
  handleErrors = stripTrail (subst {
    "@CODES_EXPR@" = codesExpr;
    "@ERR_ROOT@"   = lib.removeSuffix "/error.html" eh.error_html;
    "@ERR_FILE@"   = baseNameOf eh.error_html;
  } (readTpl "22-handle-errors.caddy.tpl"));

  # ── layer4 SNI mux (caddy-l4 module) — caddy-public IS the smart :443 edge ──
  # Replaces the blind caddy-l4-public relay. Three tiers, evaluated in order
  # (caddy-l4 #294 flat pattern: a final `not { tls { sni … } }` forces the
  # ClientHello parse so the bare-tls prefetch race can't win):
  #   1. mail SNIs (imap./smtps.) → L4-forward to maddy — raw IMAPS/SMTPS, never L7.
  #   2. pure-public SNIs → local :8443 with PROXY-protocol (L7 terminate + serve).
  #   3. everything else (private + mixed api./analytics.) → raw-TLS passthrough to
  #      gcp-proxy (private_forward_upstream). No termination ⇒ no re-encryption;
  #      gcp-proxy terminates + its @wg gate 403s public clients (source 10.1.0.1).
  mailL4     = caddyPublic.mail_l4_routes or [];
  publicSnis = caddyPublic.public_sni_hosts or [];
  sniSlug    = h: lib.replaceStrings [ "." "-" ] [ "_" "_" ] h;
  allMuxSnis = (map (r: r.sni) mailL4) ++ publicSnis;
  mkMailL4Route = r: ''
        @m_${sniSlug r.sni} tls sni ${r.sni}
        route @m_${sniSlug r.sni} {
          proxy {
            upstream ${r.upstream}
          }
        }'';
  l4Section = ''

      layer4 {
        :443 {
${lib.concatMapStringsSep "\n" mkMailL4Route mailL4}
          @public tls sni ${lib.concatStringsSep " " publicSnis}
          route @public {
            proxy {
              proxy_protocol v2
              upstream 127.0.0.1:8443
            }
          }
          @rest not {
            tls {
              sni ${lib.concatStringsSep " " allMuxSnis}
            }
          }
          route @rest {
            proxy {
              upstream ${privateUpstream}
            }
          }
        }
      }'';

  # ── Globals block (snippet-driven from 00-globals.caddy.tpl) ──
  # https_port 8443 (the L7 server), proxy_protocol→tls listener_wrapper (unwraps
  # the PP from our own layer4 tier-2), ACME DNS-01 (Cloudflare wildcard cert).
  # @L4_SECTION@ = the layer4 mux above — caddy-public owns 0.0.0.0:443 directly.
  global = caddyPublic.global or {};
  odt    = caddyPublic.on_demand_tls or {};
  globalsBlock = subst {
    "@DEBUG_LINE@"  = if (global.debug or false) then "debug" else "";
    "@ADMIN_BIND@"  = global.admin_bind;
    "@ORDER@"       = global.order;
    "@AUTO_HTTPS@"  = global.auto_https;
    "@ODT_ASK_URL@" = odt.ask_url or "http://127.0.0.1:2020";
    "@L4_SECTION@"  = l4Section;
  } (readTpl "00-globals.caddy.tpl");

  # ── Helpers to recognise gh-pages domains (multi-domain "a, b" field) ──
  ghPages = caddyPublic.github_pages_proxies or [];
  ghPagesDomainLists = map (g: lib.splitString ", " g.domain) ghPages;
  ghPagesDomains = lib.flatten ghPagesDomainLists;

  wellKnownRoutes = caddyPublic.well_known_routes or [];

  mkGithubProxy = path: ''
    rewrite * /${path}{uri}
    reverse_proxy https://diegonmarcos.github.io {
      header_up Host diegonmarcos.github.io
      ${xreal}
    }'';

  # ── well-known handle block (public per spec) ──
  mkWellKnownBlock = wk:
    let
      hasRedirect = (wk.redirect_to or null) != null;
      hasTlsSkipVerify = wk.tls_skip_verify or false;
    in
    if hasRedirect then
      # 3-arg redir form is unambiguous: <matcher=path> <to> <code>.
      "      redir ${wk.path} ${wk.redirect_to} 308"
    else if hasTlsSkipVerify then ''
      handle ${wk.path} {
        reverse_proxy https://${wk.upstream} {
          ${xreal}
          transport http {
            tls_insecure_skip_verify
          }
        }
      }''
    else ''
      handle ${wk.path} {
        reverse_proxy ${wk.upstream} {
          ${xreal}
        }
      }'';

  # ── GitHub Pages site blocks ──
  # If a gh-pages domain ALSO appears as a well_known target_domain, emit
  # those well-known handlers BEFORE the gh-pages catch-all.
  mkGithubPagesRoute = group:
    let
      groupDomains = lib.splitString ", " group.domain;
      matchingWellKnown = builtins.filter
        (wk: builtins.elem wk.target_domain groupDomains) wellKnownRoutes;
      wellKnownBlocks = lib.concatMapStringsSep "\n" mkWellKnownBlock matchingWellKnown;
      # WKD (PGP key discovery, /.well-known/openpgpkey/*) is served from
      # /srv/wkd on gcp-proxy — caddy-public has no key store, so forward it to
      # the hub (NOT the gh-pages catch-all, which would 404 on github.io).
      wkdBlock = if (group.wkd or false) then ''
      handle /.well-known/openpgpkey/* {
        ${fwd}
      }'' else "";
      body =
        if (wellKnownBlocks != "" || wkdBlock != "") then ''
      ${wkdBlock}
      ${wellKnownBlocks}
          handle {
            ${mkGithubProxy group.github_path}
          }''
        else "      ${mkGithubProxy group.github_path}";
    in ''
    # gh-pages: ${group.comment or group.domain}
    ${group.domain} {
    ${sec}
      ${body}
      ${handleErrors}
    }'';

  # ── Public subdomains (public_routes) ──
  # auth=="none" → serve the real upstream at the edge.
  # auth!=="none" → forward to gcp-proxy (do NOT serve unauthed).
  mkSubdomainRoute = route:
    let isNoAuth = (route.auth or null) == "none";
    in ''
    # subdomain: ${route.comment or route.domain}
    ${route.domain} {
    ${sec}
    ${if isNoAuth then ''  reverse_proxy ${route.upstream} {
        ${xreal}
      }'' else "  ${fwd}"}
      ${handleErrors}
    }'';

  # ── Public path-route groups (public_path_routes) ──
  # Serve ONLY each path's explicit `public_paths`; the base_path itself is
  # authed/private and is NOT served — it falls into the site catch-all that
  # forwards to gcp-proxy. The catch-all guarantees every non-public path on
  # the host forwards to the private hub (fail-closed).
  mkPublicPathHandle = upstream: pp: ''
      handle ${pp} {
        reverse_proxy ${upstream} {
          ${xreal}
        }
      }'';

  mkPathRouteGroup = group:
    let
      mkPathPublicHandles = path:
        let publicPaths = path.public_paths or [];
        in lib.concatMapStringsSep "\n" (mkPublicPathHandle path.upstream) publicPaths;
      publicHandles = lib.concatStringsSep "\n"
        (builtins.filter (s: s != "") (map mkPathPublicHandles group.paths));
    in ''
    # path-host: ${group.comment or group.parent_domain}
    ${group.parent_domain} {
    ${sec}
    ${publicHandles}
      handle {
        ${fwd}
      }
      ${handleErrors}
    }'';

  # ── well_known_routes whose target_domain is NOT a gh-pages domain ──
  # Group by target_domain → one site with the handlers + a catch-all forward.
  nonGhWellKnown = builtins.filter
    (wk: !(builtins.elem wk.target_domain ghPagesDomains)) wellKnownRoutes;

  nonGhWkDomains = lib.unique (map (wk: wk.target_domain) nonGhWellKnown);

  mkNonGhWellKnownSite = domain:
    let
      entries = builtins.filter (wk: wk.target_domain == domain) nonGhWellKnown;
      blocks = lib.concatMapStringsSep "\n" mkWellKnownBlock entries;
    in ''
    # well-known host: ${domain}
    ${domain} {
    ${sec}
    ${blocks}
      handle {
        ${fwd}
      }
      ${handleErrors}
    }'';

  # ── GLOBAL fail-closed fallback ──
  # Any *.diegonmarcos.com host not matched by an explicit named site above
  # (i.e. every private subdomain: git, vault, db, ide, …) lands here and
  # forwards to gcp-proxy (10.1.0.2:443), whose @wg gate 403s public clients.
  # MUST be the named wildcard `*.diegonmarcos.com` (NOT a port-only `:8443`):
  # caddy-public terminates TLS, so it needs a cert for the forwarded host.
  # `*.diegonmarcos.com` provisions a wildcard cert via ACME DNS-01 (acme_dns
  # cloudflare, above); a port-only site provisions no cert → TLS handshake
  # failure for every forwarded private host. https_port 8443 keeps it on :8443.
  globalFallbackBlock = ''
    # GLOBAL fail-closed fallback — forward all unmatched *.diegonmarcos.com
    # hosts to gcp-proxy over wg-public. gcp-proxy's @wg gate 403s public clients.
    *.diegonmarcos.com {
    ${sec}
      ${fwd}
      ${handleErrors}
    }'';

in ''
${globalsBlock}
  # ════════════════════════════════════════════════════════════
  # SECURITY SNIPPETS
  # ════════════════════════════════════════════════════════════

  ${securityHeaders}
  ${rateLimiting}
  ${blockBots}
  ${blockScanners}
  ${requestLimits}
  ${ipBlock}
  ${accessLog}
  ${securitySnippet}

  # ════════════════════════════════════════════════════════════
  # GITHUB PAGES PROXIES (served at edge — public static sites)
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n\n" mkGithubPagesRoute ghPages}

  # ════════════════════════════════════════════════════════════
  # PUBLIC SUBDOMAINS (auth==none — served at edge; routed here by layer4 @public)
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n\n" mkSubdomainRoute (builtins.filter (r: (r.auth or null) == "none") (caddyPublic.public_routes or []))}

  # ════════════════════════════════════════════════════════════
  # L7 DEFENCE-IN-DEPTH — only pure-public SNIs are routed to :8443 by the
  # layer4 mux (mixed/private/mail go elsewhere). Any unexpected host arriving
  # here is a mux mis-route → respond 403, NEVER serve. Legit private forwarding
  # is the L4 @rest passthrough to gcp-proxy, not an L7 reverse_proxy.
  # ════════════════════════════════════════════════════════════

  *.diegonmarcos.com {
  ${sec}
    respond "Forbidden" 403
    ${handleErrors}
  }
''
