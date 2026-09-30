# identity.nix — the edge half of reverse-proxy authentication for a vhost
# whose service declares proxy.primary.identity (gitea today):
#
#   identity = { header = "X-WEBAUTH-USER";
#                bearer  = { <client_id from introspect-proxy X-Auth-User> = <upstream user>; };
#                session = { <Authelia user from Remote-User>              = <upstream user>; }; }
#
# forward_auth (Caddy 2.11) deletes the client's copy of every copy_headers
# field before it sets them, so X-Auth-User / Remote-User are the gate's own
# words by the time `map` reads them (map is lazy: it evaluates when `respond`
# asks, i.e. after forward_auth). The upstream's user header is NOT one of
# those fields, hence the site-level strip — it runs before every handle.
# A validated identity with no row gets a 403: never anonymous, never a default.
#
# Pure builtins (no nixpkgs lib) so the tester can evaluate it standalone.
route:
let
  id = route.identity or null;
  table = name: id.${name} or {};
  # "default" is Caddy map's fallback row and "~" makes the key a regex —
  # either would hand an unmapped identity a user. Refuse to render.
  checked = tbl: builtins.mapAttrs (k: v:
    if k == "default" || builtins.substring 0 1 k == "~" || v == "" || v == "-"
    then throw "identity: row ${builtins.toJSON k} -> ${builtins.toJSON v} would map an unmapped identity to a user"
    else v) tbl;
  rows = tbl: let c = checked tbl; in builtins.concatStringsSep "\n"
    (map (k: "        ${builtins.toJSON k} ${builtins.toJSON c.${k}}") (builtins.attrNames c));
  branch = source: dest: tbl: ''

      map {http.request.header.${source}} {${dest}} {
${rows tbl}
      }
      @${dest}_unmapped vars {${dest}} ""
      respond @${dest}_unmapped "This fleet identity is not mapped to a user of this service" 403'';
in
if id == null then {
  siteStrip = ""; bearer = ""; session = ""; bearerHeaderUp = ""; sessionHeaderUp = "";
} else {
  siteStrip       = "\n      request_header -${id.header}";
  bearer          = branch "X-Auth-User" "identity_bearer_user" (table "bearer");
  session         = branch "Remote-User" "identity_session_user" (table "session");
  bearerHeaderUp  = "\n        header_up ${id.header} {identity_bearer_user}";
  sessionHeaderUp = "\n        header_up ${id.header} {identity_session_user}";
}
