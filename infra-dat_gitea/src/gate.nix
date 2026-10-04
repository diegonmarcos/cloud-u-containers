# gate.nix — renders gitea-gate's Caddyfile from build.json (gitea.gate +
# proxy.primary.identity). Pure builtins so the tester evaluates the same code
# the flake ships.
#
# trusted_proxies is the whole security boundary of reverse-proxy auth here,
# so a widened list fails the BUILD, not just a test: bare addresses only
# (no CIDR, no wildcard), and at least one.
buildJson:
let
  gate = buildJson.gitea.gate;
  trusted = gate.trusted_proxies;
  bare = p: builtins.match "[0-9a-fA-F.:]+" p != null;
  checked =
    if trusted == [] || !(builtins.all bare trusted)
    then throw "gitea.gate.trusted_proxies must be exact edge addresses (no CIDR, no *): ${builtins.toJSON trusted}"
    else trusted;
  vars = {
    "@PORT@"        = toString buildJson.ports.app;
    "@TRUSTED@"     = builtins.concatStringsSep " " checked;
    "@HOST@"        = buildJson.proxy.primary.domain;
    "@USER_HEADER@" = buildJson.proxy.primary.identity.header;
    "@SOCKET@"      = gate.socket;
  };
in
builtins.replaceStrings (builtins.attrNames vars) (builtins.attrValues vars)
  (builtins.readFile ./templates/gate.Caddyfile.tpl)
