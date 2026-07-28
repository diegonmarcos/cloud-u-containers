# ══════════════════════════════════════════════════════════════════
# caddyfile.nix — pure-Nix Caddyfile generator (v2 engine)
#
# Reads build-caddy.json (data-driven from 2_configs/dist/) and
# returns the fully-rendered Caddyfile string. Pure-syntax fragments
# live as `.caddy.tpl` files in `./snippets/`; this file only does
# orchestration: read → substitute @PLACEHOLDER@ → assemble.
#
# Last meaningful change: 2026-05-08 split snippets out of Nix string
# literals into ./snippets/*.caddy.tpl (orchestration vs data).
# ══════════════════════════════════════════════════════════════════
{ lib, caddyRoutes }:

let
  # ── Snippet loader: read .caddy.tpl + apply @KEY@ substitutions ──
  readTpl = name: builtins.readFile (./snippets + "/${name}");

  # subst :: { "@KEY@" = "value"; ... } -> string -> string
  subst = subs: text:
    lib.replaceStrings (lib.attrNames subs) (lib.attrValues subs) text;

  # Drop trailing newline (templates end with `\n`; for inline use we strip it)
  stripTrail = s: lib.removeSuffix "\n" s;

  # ── Dual-bind public *.diegonmarcos.com routes to BOTH the public socket
  # and the WG-internal IP. Hickory wildcards *.diegonmarcos.com → wgBindIp
  # for the WG fast-path (skips Cloudflare); without dual-binding here,
  # WG traffic lands on the more-specific listener created by *.app blocks
  # (which doesn't carry the public host matchers) and falls through to an
  # empty 200 response. Source-of-truth: build.json caddy_config.global.wg_bind_ip.
  wgBindIp = caddyRoutes.global.wg_bind_ip or "10.0.0.1";
  publicBindLine = "  bind 0.0.0.0 ${wgBindIp}";

  # ── Security snippets (data-driven from caddyRoutes.security_snippets) ──
  ss = caddyRoutes.security_snippets or {};

  securityHeaders = let h = ss.security_headers; in
    subst {
      "@HSTS_MAX_AGE@"      = toString h.hsts_max_age;
      "@FRAME_OPTIONS@"     = h.frame_options;
      "@REFERRER_POLICY@"   = h.referrer_policy;
      "@PERMISSIONS_POLICY@" = h.permissions_policy;
      "@CORS_ORIGIN@"       = h.cors_origin;
      "@CORS_METHODS@"      = h.cors_methods;
      "@CORS_HEADERS@"      = h.cors_headers;
      "@HIDE_HEADERS@"      = lib.concatMapStringsSep "\n        " (x: "-${x}") (h.hide_headers or []);
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

  # `sec` and `secNoLimit` are used inline as `import` lines inside site
  # blocks. Indentation is non-trivial here — we keep the original
  # whitespace exactly to preserve output formatting.
  sec = ''
      import security
      import request_limits'';

  secNoLimit = ''
      import security'';

  # ── Auth snippets ──
  auth = caddyRoutes.auth or {};
  autheliaUpstream   = caddyRoutes.auth_upstreams.authelia or "10.0.0.1:9091";
  introspectUpstream = caddyRoutes.auth_upstreams.introspect_proxy or "10.0.0.1:4182";

  authelia = stripTrail (subst {
    "@AUTHELIA_UPSTREAM@" = autheliaUpstream;
    "@AUTHELIA_URI@"      = auth.authelia_uri;
    "@AUTHELIA_COPY@"     = lib.concatStringsSep " " auth.authelia_copy;
  } (readTpl "20-authelia.caddy.tpl"));

  bearer = stripTrail (subst {
    "@INTROSPECT_UPSTREAM@" = introspectUpstream;
    "@INTROSPECT_URI@"      = auth.introspect_uri;
    "@INTROSPECT_COPY@"     = lib.concatStringsSep " " auth.introspect_copy;
  } (readTpl "21-bearer.caddy.tpl"));

  handleErrors = let
    eh = caddyRoutes.error_handler or { status_codes = [502 503 504]; error_html = "/srv/error.html"; };
    codesExpr = lib.concatMapStringsSep " || " (c: "{err.status_code} == ${toString c}") eh.status_codes;
    errPath = eh.error_html;
  in stripTrail (subst {
    "@CODES_EXPR@" = codesExpr;
    "@ERR_ROOT@"   = lib.removeSuffix "/error.html" errPath;
    "@ERR_FILE@"   = baseNameOf errPath;
  } (readTpl "22-handle-errors.caddy.tpl"));

  protectedTpl       = readTpl "23-protected.caddy.tpl";
  protectedCustomTpl = readTpl "24-protected-custom.caddy.tpl";

  # Shared empty-body guard (snippet 35): injected into every reverse_proxy
  # block so an upstream 200 with Content-Length 0 (a blank white page) becomes
  # a truthful 502 that handle_errors renders, instead of a silent false green.
  emptyGuard = stripTrail (readTpl "35-empty-body-guard.caddy.tpl");

  mkProtected = upstream: subst {
    "@BEARER_BLOCK@"   = bearer;
    "@AUTHELIA_BLOCK@" = authelia;
    "@UPSTREAM@"       = upstream;
    "@EMPTY_GUARD@"    = emptyGuard;
  } protectedTpl;

  mkProtectedCustom = upstreamUrl: transportBlock: subst {
    "@BEARER_BLOCK@"    = bearer;
    "@AUTHELIA_BLOCK@"  = authelia;
    "@UPSTREAM@"        = upstreamUrl;
    "@TRANSPORT_BLOCK@" = transportBlock;
    "@EMPTY_GUARD@"     = emptyGuard;
  } protectedCustomTpl;

  # ── WG-only gates (fail-closed posture; route.wg_only from build.json
  #    proxy.primary, defaulted true unless wg_only:false — see derive engine) ──
  # Two shapes for two scopes:
  #  · wgGateBody — wraps a single handle's BODY in an order-independent
  #    `handle @wg {…} handle { respond 403 }` pair. MUST be used INSIDE an
  #    outer handle/handle_path so the 403 catch-all is scoped to that path and
  #    never leaks to sibling routes in a shared site block. Mirrors the
  #    mkMcpRouteGroup per-endpoint pattern. Used by mkPathEntry.
  #  · wgSiteLine — a top-of-site `@not_wg not remote_ip … respond 403` guard
  #    for whole-domain blocks (relies on the global `order respond before
  #    handle`, same as mkSubdomainRoute's wgBlock). Used by mkNtfyBlock /
  #    mkProxyDashboardBlock.
  wgGateBody = isWg: body:
    if isWg then ''@wg remote_ip 10.0.0.0/24
        handle @wg {
          ${body}
        }
        handle {
          respond "Forbidden" 403
        }''
    else body;
  wgSiteLine = isWg:
    if isWg then ''@not_wg not remote_ip 10.0.0.0/24
      respond @not_wg "Forbidden" 403''
    else "";

  mkGithubProxy = path: ''
    rewrite * /${path}{uri}
    reverse_proxy https://diegonmarcos.github.io {
      header_up Host diegonmarcos.github.io
      header_up X-Real-IP {http.request.remote.host}
    }
  '';

  # ── Route generators ──
  # listen: optional — when the derive emits a "listen" field (e.g. "10.0.0.1:465"
  # for listen_scope=wg), Caddy binds only on that IP:port. Absent → :<port> =
  # all interfaces = current public behavior. One data-driven knob flips public
  # vs WG-only per entry in config.json → vms[gcp-proxy].public_ports[].
  #
  # sni: optional — when present, the route is matched by TLS SNI inside a
  # shared listener block. Multiple routes with the same listenSpec get
  # collapsed into one listener with per-SNI sub-routes. Phase 3 of the
  # public-surface collapse: lets IMAPS, SMTPS, JMAP, … all share :443 via
  # SNI hostname routing.
  routeListenSpec = route: route.listen or ":${toString route.port}";

  # Slugify hostname for caddy-l4 named matcher (dots/hyphens → underscores)
  sniSlug = host: lib.replaceStrings ["." "-"] ["_" "_"] host;

  l4PlainTpl = readTpl "50-l4-plain-route.caddy.tpl";
  l4SniTpl   = readTpl "51-l4-sni-route.caddy.tpl";

  # Plain (non-SNI) route — direct TCP proxy, used for ports like :25
  mkPlainRoute = route:
    let
      pp = route.proxy_protocol or false;
      ppLine = if pp then "\n                proxy_protocol v2" else "";
    in subst {
      "@COMMENT@"  = route.comment or "";
      "@UPSTREAM@" = route.upstream;
      "@PP_LINE@"  = ppLine;
    } l4PlainTpl;

  # Per-SNI inner dispatch route (used inside the outer @mail gate)
  mkSniInnerRoute = route:
    let
      pp = route.proxy_protocol or false;
      ppLine = if pp then "\n                  proxy_protocol v2" else "";
    in subst {
      "@COMMENT@"     = route.comment or "";
      "@SNI@"         = route.sni;
      "@SNI_MATCHER@" = "@sni_${sniSlug route.sni}";
      "@UPSTREAM@"    = route.upstream;
      "@PP_LINE@"     = ppLine;
    } l4SniTpl;

  # Group routes by listenSpec → one listener block per spec.
  groupRoutesByListen = routes:
    lib.foldl' (acc: r:
      let k = routeListenSpec r; in
      acc // { ${k} = (acc.${k} or []) ++ [ r ]; }
    ) {} routes;

  # caddy-l4 SNI mux pattern (per upstream issue #294 + tls.md docs):
  #   1. Outer @<gate> tls { sni <hostA> <hostB> ... } gates ALL mail SNIs in
  #      one matcher, forcing a single ClientHello parse before any nested
  #      matchers run. Avoids the prefetch-race where a bare `tls` matcher
  #      wins against not-yet-parsed SNI matchers.
  #   2. Inner per-SNI sub-routes dispatch to the right upstream after the
  #      outer matcher already accepted the connection.
  #   3. Default fall-through uses `not { tls { sni <hostA> ... } }` instead
  #      of bare `@any_tls tls` — bare `tls` matches on first 5 bytes (TLS
  #      record header) before SNI parse and would always win the race.
  # Source: https://github.com/mholt/caddy-l4/issues/294
  mkL4ListenerBlock = listenSpec: routes:
    let
      sniRoutes    = lib.filter (r: (r ? sni) && r.sni != null) routes;
      plainRoutes  = lib.filter (r: !((r ? sni) && r.sni != null)) routes;
      sniHostList  = map (r: r.sni) sniRoutes;
      sniArgs      = lib.concatStringsSep " " sniHostList;
      hasSni       = sniHostList != [];

      plainOut     = lib.concatMapStringsSep "\n" mkPlainRoute plainRoutes;

      # SNI mux block: flat per-SNI matchers + `not` fall-through.
      # Nested matchers inside a `route` block are NOT valid Caddyfile syntax
      # (parser treats `@name` as handler-directive). #294 pattern works flat.
      sniMuxBlock = if !hasSni then "" else ''

          # ── SNI mux (issue #294 pattern, flat) ─────────────────────────
${lib.concatMapStringsSep "\n" mkSniInnerRoute sniRoutes}
          # Fall-through: TLS that does NOT match any mail SNI → internal HTTPS
          # `not { tls { sni ... } }` forces ClientHello parse, avoiding the
          # bare-`tls` race condition (issue #294).
          @notmail not {
            tls {
              sni ${sniArgs}
            }
          }
          route @notmail {
            proxy {
              # Carry the real client address across the local hop. The
              # :8443 HTTP server unwraps it via listener_wrappers
              # proxy_protocol (00-globals.caddy.tpl), so remote_ip
              # matchers (wg-only tier gate) see the true client instead
              # of 127.0.0.1 — which had every request, including genuine
              # WG clients, answered "Forbidden" (vault regression).
              proxy_protocol v2
              upstream 127.0.0.1:8443
            }
          }'';
    in ''
        ${listenSpec} {
${plainOut}${sniMuxBlock}
        }'';

  mkL4Section =
    if (caddyRoutes.l4_routes or []) == [] then ""
    else
      let grouped = groupRoutesByListen caddyRoutes.l4_routes; in ''

      layer4 {
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkL4ListenerBlock grouped)}
      }
  '';

  mkSubdomainRoute = route:
    let
      isNoAuth = (route.auth or null) == "none";
      # The derive engine emits wg_only:true ONLY for private routes and OMITS the
      # field for public ones (wgOnly ?? true at the source). So "absent" reliably
      # means PUBLIC — default false here. Fail-closed lives at the derive, NOT here:
      # defaulting true would wrongly gate public routes (vpn WG-join, matrix federation).
      isWgOnly = route.wg_only or false;
      hasMaxUpload = (route.max_upload or null) != null;
      hasTimeout = (route.timeout or null) != null;
      hasTlsSkipVerify = route.tls_skip_verify or false;
      tlsServerName = route.tls_server_name or null;
      hasTlsServerName = tlsServerName != null;
      hasLandingPage = (route.landing_page or null) != null;
      hasBypassPaths = (route.bypass_paths or null) != null;

      secLine = if hasMaxUpload then secNoLimit else sec;
      uploadBlock = if hasMaxUpload then ''

      request_body {
        max_size ${route.max_upload}
      }'' else "";

      upstreamUrl = if hasTlsServerName || hasTlsSkipVerify then "https://${route.upstream}" else route.upstream;

      proxyBlock =
        if isNoAuth && hasTlsSkipVerify then
          ''    reverse_proxy https://${route.upstream} {
        header_up X-Real-IP {http.request.remote.host}
        transport http {
      tls_insecure_skip_verify
    }
      }''
        else if isNoAuth then
          ''    reverse_proxy ${route.upstream} {
        header_up X-Real-IP {http.request.remote.host}
      }''
        else if hasTlsServerName && hasTimeout then
          mkProtectedCustom upstreamUrl ''
        transport http {
          tls
          tls_server_name ${tlsServerName}
          read_timeout ${route.timeout}
          write_timeout ${route.timeout}
        }''
        else if hasTlsServerName then
          mkProtectedCustom upstreamUrl ''
        transport http {
          tls
          tls_server_name ${tlsServerName}
        }''
        else if hasTlsSkipVerify && hasTimeout then
          mkProtectedCustom upstreamUrl ''
        transport http {
          tls_insecure_skip_verify
          read_timeout ${route.timeout}
          write_timeout ${route.timeout}
        }''
        else if hasTlsSkipVerify then
          mkProtectedCustom upstreamUrl ''
        transport http {
          tls_insecure_skip_verify
        }''
        else if hasTimeout then
          mkProtectedCustom route.upstream ''
        transport http {
          read_timeout ${route.timeout}
          write_timeout ${route.timeout}
        }''
        else mkProtected route.upstream;

      landingBlock = if hasLandingPage then ''
      # Root path → landing page (proxied, keeps our domain)
      @root path /
      handle @root {
        ${mkGithubProxy route.landing_page}
      }

      # All other paths → auth + upstream'' else "";

      bypassBlock = if hasBypassPaths then
        lib.concatMapStringsSep "\n" (p: ''
      handle ${p} {
        reverse_proxy ${route.upstream}
      }'') route.bypass_paths
      else "";

      wgBlock = if isWgOnly then ''
      @not_wg not remote_ip 10.0.0.0/24
      respond @not_wg "Forbidden" 403'' else "";

      # Static JSON at GET / — used when the upstream's runtime response
      # leaks internal details (e.g. Stalwart JMAP Session baking :2443 into
      # apiUrl). We declare the override in service build.json under
      # proxy.primary.root_response_json; Caddy emits `handle /` with the
      # JSON serialised verbatim via Caddy's backtick `respond` body form.
      # All other paths still hit the reverse_proxy upstream.
      hasRootJson = (route.root_response_json or null) != null;
      rootJsonBlock = if hasRootJson then ''
      @root_get_only method GET HEAD
      handle @root_get_only {
        @root_path path /
        handle @root_path {
          header Content-Type application/json
          respond `${builtins.toJSON route.root_response_json}` 200
        }
      }'' else "";

      # well_known graft — any service may declare `proxy.well_known[]` with
      # `target_domain` matching this proxy route's domain. The aggregator in
      # cloud-data-config-derive.ts collects them into `well_known_routes`; we
      # filter by target_domain and emit per-path handlers BEFORE the catch-all
      # reverse_proxy. Mirrors mkGithubPagesRoute's existing behaviour so the
      # mechanism is symmetric across every Caddy route flavour.
      proxyDomains = lib.splitString ", " route.domain;
      matchingWellKnown = builtins.filter
        (wk: builtins.elem wk.target_domain proxyDomains)
        wellKnownRoutes;
      wellKnownBlock = lib.concatMapStringsSep "\n" mkWellKnownBlock matchingWellKnown;

      # When well_known handlers are emitted, the catch-all proxyBlock
      # MUST be wrapped in a `handle { }` block. In Caddy v2, mixing
      # bare directives (`reverse_proxy …`) with `handle` blocks at the
      # same site-block level lets the bare directive win for the
      # catch-all match — including the exact `/` path the well_known
      # `handle / { redir 308 }` is supposed to intercept. Symptom:
      # https://jmap.diegonmarcos.com/ returned Stalwart's JSON 404
      # instead of the declared 308 redirect to /.well-known/jmap.
      # Mirrors the existing mkGithubPagesRoute behaviour (lines 414-419)
      # so the wrap is symmetric across every Caddy route flavour.
      # WG-only routes must ALSO handle-wrap the proxy. The `@not_wg respond
      # 403` guard (wgBlock) relies on the global `order respond before handle`
      # so it pre-empts `handle` blocks — but NOT a bare `reverse_proxy` (the
      # auth:none branch, e.g. vault). Wrapping guarantees the guard fires
      # before the proxy for non-WG clients regardless of auth mode.
      wrappedProxyBlock = if (wellKnownBlock != "" || isWgOnly) then ''
      handle {
        ${proxyBlock}
      }'' else proxyBlock;

    in ''
    # ${route.comment or route.domain}
    ${route.domain} {
  ${publicBindLine}
  ${secLine}${uploadBlock}
  ${wgBlock}
  ${bypassBlock}${landingBlock}
  ${rootJsonBlock}
  ${wellKnownBlock}
      ${wrappedProxyBlock}
      ${handleErrors}
    }
  '';

  wellKnownRoutes = caddyRoutes.well_known_routes or [];

  mkWellKnownBlock = wk:
    let
      hasRedirect = (wk.redirect_to or null) != null;
      hasTlsSkipVerify = wk.tls_skip_verify or false;
      proxyDirective =
        if hasRedirect then
          # Permanent 308 — preserves method + body, avoids client surprise
          # on POST/PUT. Spec-friendly for /.well-known autoconfig.
          # Explicit `${wk.path}` matcher disambiguates Caddy's parser: the
          # 2-arg form `redir /.well-known/jmap 308` is parsed as
          # `<matcher=/.well-known/jmap> <to=308>` (because the first arg
          # starts with `/`), so the matcher never fires on `/` and the
          # directive is a no-op (empty 200). The 3-arg form
          # `redir / /.well-known/jmap 308` parses unambiguously as
          # `<matcher=/> <to=/.well-known/jmap> <code=308>`.
          "        redir ${wk.path} ${wk.redirect_to} 308"
        else if hasTlsSkipVerify then ''
          reverse_proxy https://${wk.upstream} {
            transport http {
              tls_insecure_skip_verify
            }
          }'' else "        reverse_proxy ${wk.upstream}";
    in ''
      # ${wk.comment or wk.path} (well-known — public per spec)
      handle ${wk.path} {
  ${proxyDirective}
      }'';

  mkGithubPagesRoute = route:
    let
      hasWkd = route.wkd or false;
      routeDomains = lib.splitString ", " route.domain;
      matchingWellKnown = builtins.filter (wk: builtins.elem wk.target_domain routeDomains) wellKnownRoutes;
      wellKnownBlocks = lib.concatMapStringsSep "\n" mkWellKnownBlock matchingWellKnown;

      wkdBlock = if hasWkd then ''
      # WKD — PGP public key discovery (no auth — must be public per spec)
      handle_path /.well-known/openpgpkey/* {
        root * /srv/wkd
        file_server
      }
  ${wellKnownBlocks}
      handle {
        ${mkGithubProxy route.github_path}
      }'' else if wellKnownBlocks != "" then ''
  ${wellKnownBlocks}
      handle {
        ${mkGithubProxy route.github_path}
      }'' else "    ${mkGithubProxy route.github_path}";
    in ''
    # ${route.comment or route.domain}
    ${route.domain} {
  ${publicBindLine}
  ${sec}
  ${wkdBlock}
      ${handleErrors}
    }
  '';

  mkPathRouteGroup = group:
    let
      hasLandingPage = (group.landing_page or null) != null;
      hasFallback = (group.fallback or null) != null;

      mkPathEntry = path:
        let
          isGithubPages = (path.type or null) == "github_pages";
          hasRedirectBare = path.redirect_bare or false;
          hasPublicPaths = (path.public_paths or null) != null;
          # Fail-closed: WG-only unless build.json set wg_only:false (derive default).
          # Gate is applied INSIDE each handle/handle_path so the 403 catch-all is
          # path-scoped and never swallows sibling routes in the shared site block.
          # public_paths are gated too (the "gate everything" decision).
          # Absent wg_only means PUBLIC (derive omits it for public). Default false.
          isWg = path.wg_only or false;

          redirectBlock = if hasRedirectBare then ''
      @${builtins.replaceStrings ["/"] [""] path.base_path}_bare path ${path.base_path}
      handle @${builtins.replaceStrings ["/"] [""] path.base_path}_bare {
        redir {path}/ permanent
      }
  '' else "";

          publicPathsBlock = if hasPublicPaths then
            lib.concatMapStringsSep "\n" (pp: ''
      handle ${pp} {
        ${wgGateBody isWg ''uri strip_prefix ${path.base_path}
        reverse_proxy ${path.upstream}''}
      }'') path.public_paths
          else "";

          mainBlock =
            if isGithubPages then ''
      handle_path ${path.base_path}/* {
        ${wgGateBody isWg ''rewrite * /${path.github_path}/{path}
        reverse_proxy https://diegonmarcos.github.io {
          header_up Host diegonmarcos.github.io
        }''}
      }''
            else ''
      handle_path ${path.base_path}/* {
        ${wgGateBody isWg (mkProtected path.upstream)}
      }'';

        in "${redirectBlock}${publicPathsBlock}\n${mainBlock}";

      activePaths = builtins.filter (p: p ? upstream || (p.type or null) == "github_pages") group.paths;
      pathBlocks = lib.concatMapStringsSep "\n" mkPathEntry activePaths;

      landingRootBlock = if hasLandingPage then ''
      @root path /
      handle @root {
        ${mkGithubProxy group.landing_page}
      }
  '' else "";

      fallbackBlock = if hasFallback then ''
      handle {
        ${group.fallback}
      }'' else if hasLandingPage then ''
      handle {
        ${mkGithubProxy group.landing_page}
      }'' else "";

    in ''
    # ${group.comment or group.parent_domain}
    ${group.parent_domain} {
  ${publicBindLine}
  ${sec}
  ${landingRootBlock}${pathBlocks}
  ${fallbackBlock}
      ${handleErrors}
    }
  '';

  mkMcpRouteGroup = group:
    let
      mkEndpoint = ep:
        let
          proxyBody = ''reverse_proxy ${ep.upstream} {
          flush_interval -1
          header_up X-Real-IP {http.request.remote.host}
        }'';
          # Per-endpoint WG-only gate (ep.wg_only from build.json proxy.primary.wg_only).
          # The MCP hub emits NO Authelia/bearer, so a bare proxy is fully public.
          # Invert to a `handle @wg` / `handle` pair so the deny is order-independent
          # (both are `handle` blocks → source-order, first-match-wins).
          inner = if (ep.wg_only or false) then ''@wg remote_ip 10.0.0.0/24
        handle @wg {
          ${proxyBody}
        }
        handle {
          respond "Forbidden" 403
        }'' else proxyBody;
        in ''
      handle_path ${ep.base_path}/* {
        ${inner}
      }'';
      endpointBlocks = lib.concatMapStringsSep "\n" mkEndpoint group.endpoints;
      fallbackMsg = group.fallback_message or "MCP Hub";
    in ''
    # ${group.comment or group.parent_domain}
    ${group.parent_domain} {
  ${publicBindLine}
  ${sec}
  ${endpointBlocks}
      handle {
        respond "${fallbackMsg}" 200
      }
      ${handleErrors}
    }
  '';

  mkRedirectRoute = route: ''
    # ${route.comment or route.domain}
    ${route.domain} {
  ${publicBindLine}
  ${sec}
      redir ${route.target} permanent
      ${handleErrors}
    }
  '';

  # ── Special route generators ──
  mkMailBlock =
    let mail = caddyRoutes.special.mail or null;
    in if mail == null then ""
    else let
      mkMailPath = path:
        let
          isStatic = (path.type or null) == "static";
          isNoAuth = (path.auth or null) == "none";
          hasTlsSkipVerify = path.tls_skip_verify or false;
          hasAssetPaths = (path.asset_paths or null) != null;

          proxyBlock =
            if isNoAuth && hasTlsSkipVerify then
              ''reverse_proxy https://${path.upstream} {
            transport http {
              tls_insecure_skip_verify
            }
          }''
            else if isNoAuth then
              "reverse_proxy ${path.upstream}"
            else
              mkProtected path.upstream;

          mainBlock =
            if isStatic then ''
      # ${path.comment or path.base_path} (static)
      handle ${path.base_path}/config {
        root * /srv/mail
        rewrite * /servermail-config.html
        file_server
      }
      handle ${path.base_path}* {
        root * /srv/mail
        rewrite * /servermail.html
        file_server
      }''
            else ''
      # ${path.comment or path.base_path}
      handle_path ${path.base_path}/* {
        ${proxyBlock}
      }
      handle_path ${path.base_path} {
        ${proxyBlock}
      }'';

          assetBlocks = if hasAssetPaths then
            lib.concatMapStringsSep "\n" (ap: ''
      handle ${ap}/* {
        ${proxyBlock}
      }'') path.asset_paths
          else "";

        in "${mainBlock}\n${assetBlocks}";

      pathBlocks = lib.concatMapStringsSep "\n" mkMailPath (mail.paths or []);
    in ''
    # ${mail.comment or "mail"}
    ${mail.domain} {
  ${publicBindLine}
  ${sec}
      @root path /
      handle @root {
        ${mkGithubProxy mail.landing_page}
      }

  ${pathBlocks}

      handle {
        ${mkGithubProxy mail.landing_page}
      }

      ${handleErrors}
    }
  '';

  mkNtfyBlock =
    let
      ntfy          = caddyRoutes.special.ntfy or null;
      gatewayUp     = if ntfy != null then ntfy.gateway_upstream or null else null;
      hasGateway    = gatewayUp != null;
      feedNoAuth    = (ntfy.feed_auth or "") == "none";
      # /feed* is served by the rss-gateway sidecar. Default: same 3-tier auth as
      # the main ntfy block (JWT / ntfy-token / cookie). When feed_auth=="none"
      # (wg0-only sites): bare reverse_proxy — on-mesh is the only way in, so
      # Cloud Mail polls the RSS tree without a token.
      gatewayBlock  = if !hasGateway then ""
        else if feedNoAuth then ''
      handle /feed* {
        reverse_proxy ${gatewayUp}
      }
''      else ''
      handle /feed* {
        @gw_jwt header_regexp Authorization "${auth.ntfy_jwt_pattern}"
        handle @gw_jwt {
  ${bearer}
          reverse_proxy ${gatewayUp}
        }
        @gw_token header_regexp Authorization "${auth.ntfy_token_pattern}"
        handle @gw_token {
          reverse_proxy ${gatewayUp}
        }
        handle {
  ${authelia}
          reverse_proxy ${gatewayUp}
        }
      }
'';
    in if ntfy == null then ""
    # Safety: serving /feed/* with no auth is only sound when the whole site is
    # wg0-gated — otherwise the RSS tree would be world-readable. Fail eval.
    else assert (!feedNoAuth) || (ntfy.wg_only or false);
    ''
    # ${ntfy.comment or "ntfy"}
    ${ntfy.domain} {
  ${publicBindLine}
  ${sec}
      ${wgSiteLine (ntfy.wg_only or false)}
      handle /setup {
  ${authelia}
        root * /srv
        rewrite * /ntfy-setup.html
        file_server
      }
      ${gatewayBlock}
      @authelia_jwt header_regexp Authorization "${auth.ntfy_jwt_pattern}"
      handle @authelia_jwt {
  ${bearer}
        reverse_proxy ${ntfy.upstream}
      }
      @ntfy_token header_regexp Authorization "${auth.ntfy_token_pattern}"
      handle @ntfy_token {
        reverse_proxy ${ntfy.upstream}
      }
      handle {
  ${authelia}
        reverse_proxy ${ntfy.upstream}
      }
      ${handleErrors}
    }
  '';

  mkAnalyticsBlock =
    let a = caddyRoutes.special.analytics or null;
    in if a == null then ""
    else let
      trackingPaths = lib.concatStringsSep " " a.public_tracking_paths;
      umamiPublicPaths = lib.concatStringsSep " " a.umami_public_paths;
    in ''
    # ${a.comment or "Analytics"}
    ${a.domain} {
  ${publicBindLine}
  ${sec}
      @tracking {
        path ${trackingPaths}
      }
      handle @tracking {
        reverse_proxy ${a.matomo_upstream}
      }

      @umami_public {
        path ${umamiPublicPaths}
      }
      handle @umami_public {
        uri strip_prefix /umami
        reverse_proxy ${a.umami_upstream}
      }
      handle_path /umami/* {
        @umami_bearer header Authorization Bearer*
        handle @umami_bearer {
  ${bearer}
          reverse_proxy ${a.umami_upstream}
        }
        handle {
  ${authelia}
          reverse_proxy ${a.umami_upstream}
        }
      }
      @umami_root path /umami
      handle @umami_root {
        redir /umami/ permanent
      }

      ${mkProtected a.matomo_upstream}

      ${handleErrors}
    }
  '';

  mkProxyDashboardBlock =
    let pd = caddyRoutes.special.proxy_dashboard or null;
        # When auth=="none" (WG-only sites), serve static files directly —
        # the WG network is the auth boundary, mirroring ntfy feed_auth:"none".
        isNoAuth = (pd.auth or "") == "none";
        dashboardServe = ''
        root * /srv
        rewrite * /dashboard.html
        file_server'';
    in if pd == null then ""
    else ''
    # ${pd.comment or "Proxy dashboard"}
    ${pd.domain} {
  ${publicBindLine}
  ${sec}
      ${wgSiteLine (pd.wg_only or false)}
      ${if isNoAuth then dashboardServe else ''
      @bearer header Authorization Bearer*
      handle @bearer {
  ${bearer}
        ${dashboardServe}
      }
      handle {
  ${authelia}
        ${dashboardServe}
      }''}
      ${handleErrors}
    }
  '';

  # ── Internal / canonical / portless / S3 / DB-placeholder routes ──
  internalTpl   = readTpl "30-internal-route.caddy.tpl";
  canonicalTpl  = readTpl "31-canonical-app.caddy.tpl";
  portlessTpl   = readTpl "32-portless-app.caddy.tpl";
  dbTpl         = readTpl "33-db-placeholder.caddy.tpl";
  s3Tpl         = readTpl "34-s3-route.caddy.tpl";

  mkInternalRoute = route: subst {
    "@SERVICE@"          = route.service;
    "@UPSTREAM@"         = route.upstream;
    "@EMPTY_GUARD@"      = emptyGuard;
    "@HANDLE_ERRORS@"    = handleErrors;
    "@PUBLIC_BIND_LINE@" = publicBindLine;
  } internalTpl;

  mkS3Route = route: subst {
    "@SERVICE@"          = route.service;
    "@BUCKET@"           = route.bucket;
    "@S3_ENDPOINT@"      = route.s3_endpoint;
    "@S3_HOST@"          = route.s3_host;
    "@PUBLIC_BIND_LINE@" = publicBindLine;
  } s3Tpl;

  mkCanonicalAppRoute = entry: subst {
    "@SERVICE@"          = entry.service;
    "@UPSTREAM@"         = entry.upstream;
    "@EMPTY_GUARD@"      = emptyGuard;
    "@HANDLE_ERRORS@"    = handleErrors;
    "@PUBLIC_BIND_LINE@" = publicBindLine;
  } canonicalTpl;

  msgs = caddyRoutes.messages or {};
  mkPortlessAppRoute = entry: subst {
    "@SERVICE@"          = entry.service;
    "@PLACEHOLDER_MSG@"  = msgs.portless_placeholder;
    "@PUBLIC_BIND_LINE@" = publicBindLine;
  } portlessTpl;

  canonicalHttpEntries = lib.filter
    (e: e.kind == "canonical" && (e.protocol == "http" || e.protocol == "https"))
    (caddyRoutes.all_app_urls or []);

  portlessEntries = lib.filter
    (e: e.kind == "portless")
    (caddyRoutes.all_app_urls or []);

  internalRouteNames =
    let names = map (r: r.service) (caddyRoutes.internal_routes or []);
    in lib.genAttrs names (_: true);

  dedupedCanonicals = lib.filter
    (e: !(internalRouteNames.${e.service} or false))
    canonicalHttpEntries;

  dedupedPortless = lib.filter
    (e: !(internalRouteNames.${e.service} or false))
    portlessEntries;

  dbCatalogEntries = caddyRoutes.all_db_urls or [];

  mkDbPlaceholderRoute = e: subst {
    "@SERVICE@"          = e.service;
    "@CONTAINER@"        = e.container or "?";
    "@ENGINE@"           = e.engine or "?";
    "@PORT@"             = toString (e.port or 0);
    "@UPSTREAM@"         = e.upstream or "(embedded)";
    "@DB_PATH@"          = e.path or "-";
    "@VM@"               = e.vm or "-";
    "@PUBLIC_BIND_LINE@" = publicBindLine;
  } dbTpl;

  global = caddyRoutes.global or {};
  odt    = caddyRoutes.on_demand_tls or {};

  # ── Globals block (assembled from 00-globals.caddy.tpl) ──
  globalsBlock = subst {
    "@DEBUG_LINE@"  = if (global.debug or false) then "debug" else "";
    "@ADMIN_BIND@"  = global.admin_bind;
    "@ORDER@"       = global.order;
    "@AUTO_HTTPS@"  = global.auto_https;
    "@ODT_ASK_URL@" = odt.ask_url;
    "@L4_SECTION@"  = mkL4Section;
  } (readTpl "00-globals.caddy.tpl");

  # ── On-demand TLS ask endpoint ──
  odtAskBlock = subst {
    "@ODT_ASK_PORT@"    = lib.elemAt (lib.splitString ":" odt.ask_bind) 1;
    "@ODT_ASK_BIND_IP@" = lib.elemAt (lib.splitString ":" odt.ask_bind) 0;
  } (readTpl "05-odt-ask.caddy.tpl");

  # ── MTA-STS ──
  mta = caddyRoutes.mta_sts or {};
  mtaMxLines = lib.concatMapStringsSep "\n" (m: "mx: ${m}") (mta.mx or []);
  mtaStsBlock = subst {
    "@MTA_DOMAIN@"      = mta.domain or "";
    "@PUBLIC_BIND_LINE@" = publicBindLine;
    "@SEC_NO_LIMIT@"    = secNoLimit;
    "@MTA_POLICY_PATH@" = mta.policy_path or "";
    "@MTA_MODE@"        = mta.mode or "";
    "@MTA_MX_LINES@"    = mtaMxLines;
    "@MTA_MAX_AGE@"     = toString (mta.max_age or 604800);
  } (readTpl "90-mta-sts.caddy.tpl");

  # ── Catch-all ──
  catch = caddyRoutes.catch_all or {};
  catchPage = catch.page or "/srv/error.html";
  catchAllBlock = subst {
    "@CATCH_DOMAIN@"     = catch.domain or "";
    "@PUBLIC_BIND_LINE@" = publicBindLine;
    "@SEC_NO_LIMIT@"     = secNoLimit;
    "@CATCH_ROOT@"       = lib.removeSuffix ("/" + baseNameOf catchPage) catchPage;
    "@CATCH_FILE@"       = baseNameOf catchPage;
  } (readTpl "99-catch-all.caddy.tpl");

in ''
${globalsBlock}
${odtAskBlock}
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
  # SUBDOMAIN ROUTES (from routes[])
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkSubdomainRoute caddyRoutes.routes}

  # ════════════════════════════════════════════════════════════
  # GITHUB PAGES PROXIES (from github_pages_proxies[])
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkGithubPagesRoute caddyRoutes.github_pages_proxies}

  # ════════════════════════════════════════════════════════════
  # PATH-BASED ROUTES (from path_routes[])
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkPathRouteGroup caddyRoutes.path_routes}

  # ════════════════════════════════════════════════════════════
  # MCP ROUTES (from mcp_routes[])
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkMcpRouteGroup caddyRoutes.mcp_routes}

  # ════════════════════════════════════════════════════════════
  # REDIRECTS (from redirects[])
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkRedirectRoute (caddyRoutes.redirects or [])}

  # ════════════════════════════════════════════════════════════
  # SPECIAL ROUTES (from special{})
  # ════════════════════════════════════════════════════════════

${mkMailBlock}

${mkAnalyticsBlock}

${mkNtfyBlock}

${mkProxyDashboardBlock}

  # ════════════════════════════════════════════════════════════
  # INTERNAL ROUTES — portless *.app via HTTP:80 on WireGuard
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkInternalRoute (caddyRoutes.internal_routes or [])}

  # ════════════════════════════════════════════════════════════
  # APP URL ALIASES — {container}-{protocol}-{port}.app canonical routes
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkCanonicalAppRoute dedupedCanonicals}

${lib.concatMapStringsSep "\n" mkPortlessAppRoute dedupedPortless}

  # ════════════════════════════════════════════════════════════
  # DB ZONE — {container}-{engine}-{port}.db HTTPS catalog endpoints
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkDbPlaceholderRoute dbCatalogEntries}

  # ════════════════════════════════════════════════════════════
  # S3 ROUTES — OCI Object Storage via .app short names
  # ════════════════════════════════════════════════════════════

${lib.concatMapStringsSep "\n" mkS3Route (caddyRoutes.s3_routes or [])}

  # ════════════════════════════════════════════════════════════
  # MTA-STS — enforce TLS for inbound email delivery
  # ════════════════════════════════════════════════════════════

${mtaStsBlock}

  # ════════════════════════════════════════════════════════════
  # CATCH-ALL — data-driven from caddyRoutes.catch_all
  # ════════════════════════════════════════════════════════════

${catchAllBlock}
''
