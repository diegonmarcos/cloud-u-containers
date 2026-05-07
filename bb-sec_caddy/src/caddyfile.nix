# ══════════════════════════════════════════════════════════════════
# caddyfile.nix — pure-Nix Caddyfile generator (v2 engine)
#
# Reads build-caddy.json (data-driven from 2_configs/dist/) and
# returns the fully-rendered Caddyfile string. Split out of
# flake.nix so the orchestrator stays thin.
# ══════════════════════════════════════════════════════════════════
{ lib, caddyRoutes }:

let
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

  securityHeaders = let h = ss.security_headers; in ''
    (security_headers) {
      header {
        Strict-Transport-Security "max-age=${toString h.hsts_max_age}; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "${h.frame_options}"
        Referrer-Policy "${h.referrer_policy}"
        Permissions-Policy "${h.permissions_policy}"
        Access-Control-Allow-Origin "${h.cors_origin}"
        Access-Control-Allow-Methods "${h.cors_methods}"
        Access-Control-Allow-Headers "${h.cors_headers}"
        ${lib.concatMapStringsSep "\n        " (x: "-${x}") (h.hide_headers or [])}
      }
    }
  '';

  rateLimiting = let r = ss.rate_limit; in ''
    (rate_limiting) {
      rate_limit {
        zone ${r.zone} {
          key    ${r.key}
          events ${toString r.events}
          window ${r.window}
        }
      }
    }
  '';

  blockBots = let uas = lib.concatStringsSep "|" ss.bot_blocker.user_agents; in ''
    (block_bots) {
      @bad_bots header_regexp User-Agent "(?i)(${uas})"
      respond @bad_bots 403
    }
  '';

  blockScanners = let paths = lib.concatStringsSep " " ss.scanner_blocker.paths; in ''
    (block_scanners) {
      @blocked_paths path ${paths}
      respond @blocked_paths 404
    }
  '';

  requestLimits = let r = ss.request_limits; in ''
    (request_limits) {
      request_body {
        max_size ${r.max_body}
      }
    }
  '';

  ipBlock = let cidrs = ss.ip_block.cidrs or []; in ''
    (ip_block) {
      ${if cidrs == [] then "# no blocked CIDRs" else ''
      @blocked_ips remote_ip ${lib.concatStringsSep " " cidrs}
      respond @blocked_ips 403''}
    }
  '';

  accessLog = let a = ss.access_log; in ''
    (access_log) {
      log {
        output file ${a.path} {
          roll_size ${a.roll_size}
          roll_keep ${toString a.roll_keep}
        }
        format ${a.format}
      }
    }
  '';

  securitySnippet = ''
    (security) {
      import security_headers
      import block_bots
      import block_scanners
      import rate_limiting
      import ip_block
      import access_log
    }
  '';

  sec = ''
      import security
      import request_limits'';

  secNoLimit = ''
      import security'';

  # ── Auth snippets ──
  auth = caddyRoutes.auth or {};
  autheliaUpstream   = caddyRoutes.auth_upstreams.authelia or "10.0.0.1:9091";
  introspectUpstream = caddyRoutes.auth_upstreams.introspect_proxy or "10.0.0.1:4182";

  authelia = ''
      forward_auth ${autheliaUpstream} {
        uri ${auth.authelia_uri}
        copy_headers ${lib.concatStringsSep " " auth.authelia_copy}
      }'';

  bearer = ''
      forward_auth ${introspectUpstream} {
        method GET
        uri ${auth.introspect_uri}
        copy_headers ${lib.concatStringsSep " " auth.introspect_copy}
      }'';

  handleErrors = let eh = caddyRoutes.error_handler or { status_codes = [502 503 504]; error_html = "/srv/error.html"; };
                     codesExpr = lib.concatMapStringsSep " || " (c: "{err.status_code} == ${toString c}") eh.status_codes;
                     errPath = eh.error_html; in ''
    handle_errors {
      @backend_error expression `${codesExpr}`
      handle @backend_error {
        root * ${lib.removeSuffix "/error.html" errPath}
        rewrite * /${baseNameOf errPath}
        file_server
      }
    }'';

  mkProtected = upstream: ''
    @bearer header Authorization Bearer*
    handle @bearer {
  ${bearer}
      reverse_proxy ${upstream}
    }
    handle {
  ${authelia}
      reverse_proxy ${upstream}
    }
  '';

  mkGithubProxy = path: ''
    rewrite * /${path}{uri}
    reverse_proxy https://diegonmarcos.github.io {
      header_up Host diegonmarcos.github.io
    }
  '';

  mkProtectedCustom = upstreamUrl: transportBlock: ''
    @bearer header Authorization Bearer*
    handle @bearer {
  ${bearer}
      reverse_proxy ${upstreamUrl} {
        ${transportBlock}
      }
    }
    handle {
  ${authelia}
      reverse_proxy ${upstreamUrl} {
        ${transportBlock}
      }
    }
  '';

  # ── Route generators ──
  # listen: optional — when the derive emits a "listen" field (e.g. "10.0.0.1:465"
  # for listen_scope=wg), Caddy binds only on that IP:port. Absent → :<port> =
  # all interfaces = current public behavior. One data-driven knob flips public
  # vs WG-only per entry in config.json → vms[gcp-proxy].public_ports[].
  mkL4Block = route:
    let
      pp = route.proxy_protocol or false;
      ppLine = if pp then "\n                proxy_protocol v2" else "";
      listenSpec = route.listen or ":${toString route.port}";
    in ''
        # ${route.comment or ""}
        ${listenSpec} {
          route {
            proxy {
              upstream ${route.upstream}${ppLine}
            }
          }
        }'';

  mkL4Section =
    if (caddyRoutes.l4_routes or []) == [] then ""
    else ''

      layer4 {
  ${lib.concatMapStringsSep "\n" mkL4Block caddyRoutes.l4_routes}
      }
  '';

  mkSubdomainRoute = route:
    let
      isNoAuth = (route.auth or null) == "none";
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
        transport http {
      tls_insecure_skip_verify
    }
      }''
        else if isNoAuth then
          "    reverse_proxy ${route.upstream}"
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

    in ''
    # ${route.comment or route.domain}
    ${route.domain} {
  ${publicBindLine}
  ${secLine}${uploadBlock}
  ${wgBlock}
  ${bypassBlock}${landingBlock}
      ${proxyBlock}
      ${handleErrors}
    }
  '';

  wellKnownRoutes = caddyRoutes.well_known_routes or [];

  mkWellKnownBlock = wk:
    let
      hasTlsSkipVerify = wk.tls_skip_verify or false;
      proxyDirective = if hasTlsSkipVerify then ''
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

          redirectBlock = if hasRedirectBare then ''
      @${builtins.replaceStrings ["/"] [""] path.base_path}_bare path ${path.base_path}
      handle @${builtins.replaceStrings ["/"] [""] path.base_path}_bare {
        redir {path}/ permanent
      }
  '' else "";

          publicPathsBlock = if hasPublicPaths then
            lib.concatMapStringsSep "\n" (pp: ''
      handle ${pp} {
        uri strip_prefix ${path.base_path}
        reverse_proxy ${path.upstream}
      }'') path.public_paths
          else "";

          mainBlock =
            if isGithubPages then ''
      handle_path ${path.base_path}/* {
        rewrite * /${path.github_path}/{path}
        reverse_proxy https://diegonmarcos.github.io {
          header_up Host diegonmarcos.github.io
        }
      }''
            else ''
      handle_path ${path.base_path}/* {
        ${mkProtected path.upstream}
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
      mkEndpoint = ep: ''
      handle_path ${ep.base_path}/* {
        reverse_proxy ${ep.upstream} {
          flush_interval -1
        }
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
    let ntfy = caddyRoutes.special.ntfy or null;
    in if ntfy == null then ""
    else ''
    # ${ntfy.comment or "ntfy"}
    ${ntfy.domain} {
  ${publicBindLine}
  ${sec}
      handle /setup {
  ${authelia}
        root * /srv
        rewrite * /ntfy-setup.html
        file_server
      }
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
    in if pd == null then ""
    else ''
    # ${pd.comment or "Proxy dashboard"}
    ${pd.domain} {
  ${publicBindLine}
  ${sec}
      @bearer header Authorization Bearer*
      handle @bearer {
  ${bearer}
        root * /srv
        rewrite * /dashboard.html
        file_server
      }
      handle {
  ${authelia}
        root * /srv
        rewrite * /dashboard.html
        file_server
      }
      ${handleErrors}
    }
  '';

  mkInternalRoute = route: ''
    ${route.service} {
      bind 10.0.0.1
      tls internal
      reverse_proxy ${route.upstream}
    }
  '';

  mkS3Route = route: ''
    ${route.service} {
      bind 10.0.0.1
      tls internal
      rewrite * /${route.bucket}{uri}
      reverse_proxy ${route.s3_endpoint} {
        header_up Host ${route.s3_host}
      }
    }
  '';

  mkCanonicalAppRoute = entry: ''
    ${entry.service} {
      bind 10.0.0.1
      tls internal {
        on_demand
      }
      reverse_proxy ${entry.upstream}
    }
  '';

  msgs = caddyRoutes.messages or {};
  mkPortlessAppRoute = entry: ''
    ${entry.service} {
      bind 10.0.0.1
      tls internal {
        on_demand
      }
      respond "${msgs.portless_placeholder}" 204
    }
  '';

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

  mkDbPlaceholderRoute = e: ''
    ${e.service} {
      bind 10.0.0.1
      tls internal {
        on_demand
      }
      respond "DB catalog — container=${e.container or "?"} engine=${e.engine or "?"} port=${toString (e.port or 0)} upstream=${e.upstream or "(embedded)"} path=${e.path or "-"} vm=${e.vm or "-"}" 200
    }
  '';

  global = caddyRoutes.global or {};
  odt    = caddyRoutes.on_demand_tls or {};

in ''
  {
    # Upstreams use raw WG IPs (not DNS) — Caddy is the *.app target
    ${if (global.debug or false) then "debug" else ""}
    admin ${global.admin_bind}
    order ${global.order}
    auto_https ${global.auto_https}
    on_demand_tls {
      ask ${odt.ask_url}
    }
${mkL4Section}
  }

  # ── On-demand TLS ask endpoint ──
  :${lib.elemAt (lib.splitString ":" odt.ask_bind) 1} {
    bind ${lib.elemAt (lib.splitString ":" odt.ask_bind) 0}
    respond 200
  }

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

  ${(caddyRoutes.mta_sts or {}).domain} {
  ${publicBindLine}
${secNoLimit}
    tls {
      dns cloudflare {env.CF_API_TOKEN}
      resolvers 1.1.1.1 8.8.8.8
      propagation_delay 30s
      propagation_timeout 5m
    }
    handle ${(caddyRoutes.mta_sts or {}).policy_path} {
      header Content-Type "text/plain"
      respond "version: STSv1
mode: ${(caddyRoutes.mta_sts or {}).mode}
${lib.concatMapStringsSep "\n" (m: "mx: ${m}") ((caddyRoutes.mta_sts or {}).mx or [])}
max_age: ${toString ((caddyRoutes.mta_sts or {}).max_age or 604800)}
" 200
    }
    respond 404
  }

  # ════════════════════════════════════════════════════════════
  # CATCH-ALL — data-driven from caddyRoutes.catch_all
  # ════════════════════════════════════════════════════════════

  ${(caddyRoutes.catch_all or {}).domain} {
  ${publicBindLine}
${secNoLimit}
    tls {
      dns cloudflare {env.CF_API_TOKEN}
      resolvers 1.1.1.1 8.8.8.8
      propagation_delay 30s
      propagation_timeout 5m
    }
    root * ${lib.removeSuffix ("/" + baseNameOf ((caddyRoutes.catch_all or {}).page or "")) ((caddyRoutes.catch_all or {}).page or "/srv/error.html")}
    rewrite * /${baseNameOf ((caddyRoutes.catch_all or {}).page or "error.html")}
    file_server
  }

''
