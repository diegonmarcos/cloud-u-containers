# mcp-oauth.nix — Caddy handle blocks for the MCP OAuth authorization server
# (infra-sec_mcp-oauth, option 31.1, WIP — branch wip/mcp-oauth only).
#
# Rendered INSIDE the mcp.diegonmarcos.com site block of BOTH Caddyfiles (hub
# infra-sec_caddy, edge infra-sec_caddy-public), before the per-endpoint
# handle_path blocks so /<svc>/.well-known/... and /<svc>/register hit the AS
# instead of the tool endpoint.
#
# Data: caddy_config.mcp_oauth (infra-sec_caddy/build.json), copied by the derive
# into build-caddy.json / build-caddy-edge.json. ABSENT => renders nothing, so this
# file is inert until the derive carries the block (that is the "ship" switch).
#
# Tiers (owner rule "public URL = bearer or Authelia cookie"):
#   · open_paths      -> public-open, exactly the paths already listed for this host
#                        in edge_auth.public_open (the build asserts the subset).
#   · authorize_paths -> ALSO listed public_open (the shared gate is skipped), but
#                        guarded here by an explicit Authelia forward_auth: no session,
#                        no consent page, no code. Remote-User comes only from Authelia
#                        (forward_auth copy_headers replaces any client-sent value).
#   · /introspect, /revoke, /health -> never routed: mesh-only on bind_host.
{ lib, cfg, edgeAuth, autheliaUpstream, auth ? {} }:

if cfg == null then { block = _: ""; deny = _: _: null; } else
let
  openFor = host: lib.concatMap (e: e.paths or [])
    (lib.filter (e: (e.scope or "") == "paths" && e.host == host) (edgeAuth.public_open or []));
  declared = openFor cfg.host;
  wanted = cfg.open_paths ++ cfg.authorize_paths;
  missing = lib.filter (p: !(builtins.elem p declared)) wanted;
  paths = ps: lib.concatStringsSep " " ps;
  proxy = ''reverse_proxy ${cfg.upstream} {
          header_up X-Real-IP {http.request.remote.host}
          header_up -Remote-User
          header_up -Remote-Email
          header_up -Remote-Groups
        }'';
in
assert missing == [] ||
  throw "mcp_oauth: paths not declared in edge_auth.public_open for ${cfg.host}: ${toString missing}";
{
  # MCP 2025-06 s2.3.1: an unauthenticated call to a protected tool endpoint must be
  # 401 + WWW-Authenticate pointing at its RFC 9728 metadata. Returns null for other
  # hosts / when unconfigured so the caller keeps its 403.
  deny = host: basePath: if host != cfg.host then null else ''
        handle {
          header WWW-Authenticate `Bearer resource_metadata="https://${cfg.host}/.well-known/oauth-protected-resource${basePath}/mcp"`
          respond "Unauthorized" 401
        }'';

  block = host: if host != cfg.host then "" else ''
      # ── MCP OAuth AS (infra-sec_mcp-oauth) — discovery / DCR / token: public-open ──
      @mcp_oauth_open path ${paths cfg.open_paths}
      handle @mcp_oauth_open {
        ${proxy}
      }
      # ── /authorize: Authelia session REQUIRED (forward_auth), then the AS ──
      @mcp_oauth_authz path ${paths cfg.authorize_paths}
      handle @mcp_oauth_authz {
        forward_auth ${autheliaUpstream} {
          uri ${auth.authelia_uri or "/api/authz/forward-auth"}
          header_up X-Forwarded-Uri {http.request.orig_uri}
          copy_headers Remote-User Remote-Email Remote-Groups
        }
        reverse_proxy ${cfg.upstream} {
          header_up X-Real-IP {http.request.remote.host}
        }
      }'';
}
