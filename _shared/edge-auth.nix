# ══════════════════════════════════════════════════════════════════
# edge-auth.nix — the ONE shared public-edge auth gate, rendered into BOTH
# Caddyfiles (hub: infra-sec_caddy, edge: infra-sec_caddy-public).
#
# Policy (owner, 2026-10-16) lives in build.json caddy_config.edge_auth and is
# carried by the derive into build-caddy.json / build-caddy-edge.json:
#   a) private          — mesh only (wg_only / *.app): 403 to every non-mesh source
#   b) public-protected — DEFAULT for anything public: `import edge_auth`
#   c) public-open      — ONLY hosts listed in edge_auth.public_open (each with a reason)
# The CI guard (cloud-infra 9_others/test/edge-auth-gate.test.sh) renders both
# Caddyfiles' dist and fails on a site that is in no tier or in two.
#
# Two flavours of the same snippet:
#   edge_auth          — enforced for every source           (public hosts)
#   edge_auth_offmesh  — enforced only for NON-mesh sources  (hosts whose mesh
#                        clients are already trusted by the WG gate: mcp.,
#                        and wg_only vhosts that deliberately expose a few paths
#                        off-mesh, e.g. JMAP discovery)
# ══════════════════════════════════════════════════════════════════
{ lib
, edgeAuth ? {}            # caddy_config.edge_auth from the build json
, auth                     # caddy_config.auth (uris + copy_headers)
, autheliaUpstream         # forward_auth target for the session branch
, introspectUpstream       # forward_auth target for the bearer branch
, wgCidrs                  # mesh source CIDRs (space separated)
}:
# Fail closed AND loud: a build json without the policy block (e.g. the derive
# ran from a checkout that predates it) must break the render. Rendering with an
# empty list would gate auth. with its own gate -- a login lockout.
assert (edgeAuth.public_open or []) != [] ||
  throw "edge_auth.public_open missing from the build json: refusing to render a Caddyfile without the declared tier list (infra-sec_caddy/build.json caddy_config.edge_auth)";
let
  tpl = builtins.readFile ./edge-auth.caddy.tpl;
  subst = subs: text: lib.replaceStrings (lib.attrNames subs) (lib.attrValues subs) text;

  note = name: offmesh: ws:
    if ws then "  # ${name}: enforced for every source EXCEPT `Upgrade: websocket` requests (wstunnel on vpn.)."
    else if offmesh then "  # ${name}: same gate, enforced only against NON-mesh sources (mesh peers are trusted by the WG gate)."
    else "  # ${name}: enforced for every source.";

  mk = name: offmesh: ws: note name offmesh ws + "\n" + lib.removeSuffix "\n" (subst {
    "@GATE@"                = name;
    "@EA_OFFMESH@"          = if offmesh then "\n      not remote_ip ${wgCidrs}" else "";
    # WebSocket-upgrade exemption (wstunnel on vpn.): the client cannot do a
    # bearer/cookie handshake; the server enforces its own secret path prefix.
    "@EA_EXTRA@"            = if ws then "\n      not header Upgrade websocket" else "";
    "@INTROSPECT_UPSTREAM@" = introspectUpstream;
    "@INTROSPECT_URI@"      = auth.introspect_uri or "/auth";
    "@INTROSPECT_COPY@"     = lib.concatStringsSep " " (auth.introspect_copy or [ "X-Auth-User" ]);
    "@AUTHELIA_UPSTREAM@"   = autheliaUpstream;
    "@AUTHELIA_URI@"        = auth.authelia_uri or "/api/authz/forward-auth";
    "@AUTHELIA_COPY@"       = lib.concatStringsSep " " (auth.authelia_copy or [ "Remote-User" ]);
  } tpl);

  entries   = edgeAuth.public_open or [];
  openHosts = map (e: e.host) (lib.filter (e: (e.scope or "host") == "host") entries);
  hostsOf = domain: map (s: builtins.head (lib.splitString "/" s)) (lib.splitString ", " domain);
  # Always exempt on every host (owner-approved tier c): ACME http-01.
  acmePath = "/.well-known/acme-challenge/*";
  pathsOf = host: lib.concatMap (e: e.paths or []) (lib.filter (e: (e.scope or "") == "paths" && e.host == host) entries);
  # TEMPORARY, explicit, reported by the guard on every run: hosts whose gate is
  # held back until their client can authenticate (edge_auth.held). Remove the
  # entry to gate them.
  heldHosts = map (e: e.host) (edgeAuth.held or []);
  wsHosts = map (e: e.host) (lib.filter (e: (e.scope or "") == "websocket") entries);
  argsFor = domain: lib.concatStringsSep " " ([ acmePath ] ++ lib.concatMap pathsOf (hostsOf domain));
in rec {
  inherit openHosts;

  # The two (snippet) definitions, emitted once per Caddyfile.
  snippets = ''
  # (edge_auth) -- the ONE public-edge auth gate (cloud-u-containers _shared/edge-auth.*).
  # Owner rule 2026-10-16: PUBLIC URL = fleet Bearer OR Authelia session cookie.
  #   - `Authorization: Bearer ...` -> introspect-proxy (the same door the MCP routes
  #     use); an invalid token gets the introspector's own 401/403.
  #   - `X-Fleet-Authorization: Bearer ...` -> the same introspect-proxy (the token is
  #     moved into Authorization on the sub-request only); it wins over Authorization
  #     and is stripped before proxying, so a mailbox credential in `Authorization`
  #     (Stalwart Basic/Bearer on jmap./mails.) reaches the upstream untouched.
  #   - anything else -> Authelia forward-auth: a valid session cookie passes;
  #     otherwise Authelia answers 401 to API / non-browser clients and 302 to
  #     auth. (with rd=) to browsers. Nothing reaches an upstream anonymously.
  #   - Tier c (public_open in build.json caddy_config.edge_auth) is exempted by
  #     the PATH ARGS of the import: `import edge_auth <path>...` -- always
  #     /.well-known/acme-challenge/* plus that host's own declared paths.
  #   - CORS preflight (OPTIONS + Access-Control-Request-Method) cannot carry
  #     credentials: it is answered 204 right here and never proxied. Plain
  #     OPTIONS (WebDAV) is still gated.
  # forward_auth sorts before handle / respond / reverse_proxy, so importing this
  # at the top of a site gates every handle in it. `redir` sorts BEFORE
  # forward_auth: a site-level `redir` next to this import would run ungated, so
  # it must be wrapped in `handle { }` (the CI guard rejects a bare one).
${mk "edge_auth" false false}
${mk "edge_auth_offmesh" true false}
${mk "edge_auth_ws" false true}
'';

  # True when EVERY name of a (possibly "a, b"-joined) site address is declared public-open.
  isOpen = domain: let hs = hostsOf domain; in hs != [] && lib.all (h: builtins.elem h openHosts) hs;

  # The line a site block carries. Public-open hosts carry none (the guard checks
  # they are listed); everything else imports the gate.
  # `kind`: "all" (default flavour) or "offmesh". A host declared websocket-exempt
  # gets edge_auth_ws instead.
  gateKind = kind: domain:
    if isOpen domain || lib.any (h: builtins.elem h heldHosts) (hostsOf domain) then ""
    else let hs = hostsOf domain; isWs = lib.any (h: builtins.elem h wsHosts) hs;
         name = if isWs then "edge_auth_ws" else if kind == "offmesh" then "edge_auth_offmesh" else "edge_auth";
    in "import ${name} ${argsFor domain}";
  gate    = gateKind "all";
  gateOff = gateKind "offmesh";
}
