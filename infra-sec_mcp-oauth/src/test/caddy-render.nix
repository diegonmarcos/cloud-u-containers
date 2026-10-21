# lib is passed in (test-caddy-render.sh pins it); no <nixpkgs> / NIX_PATH dependency.
{ root, lib, cfgOverride ? null }:
let
  bj = builtins.fromJSON (builtins.readFile (root + "/infra-sec_caddy/build.json"));
  cc = bj.caddy_config;
  mo = import (root + "/_shared/mcp-oauth.nix") {
    inherit lib; auth = {}; autheliaUpstream = "172.18.0.3:9091";
    cfg = if cfgOverride == null then cc.mcp_oauth else cfgOverride; edgeAuth = cc.edge_auth;
  };
  off = import (root + "/_shared/mcp-oauth.nix") { inherit lib; auth = {}; autheliaUpstream = "x"; cfg = null; edgeAuth = {}; };
in { on = mo.block "mcp.diegonmarcos.com"; other = mo.block "x.diegonmarcos.com"; off = off.block "mcp.diegonmarcos.com"; }
