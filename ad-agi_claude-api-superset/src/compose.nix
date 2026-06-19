# compose.nix — docker-compose for claude-api-superset.
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# WG-ONLY sidecar (inherited from kg-bridge): host network, listeners bound to the
# VM's WireGuard IP (10.0.0.6) — reachable only across the WG mesh, NEVER the public
# NIC. No Caddy route, no published port, public:false. Callers (octocode/cgc, the
# desktop/termux fallback client) reach it at <wg-ip>:PORT over WG.
#
# AUTH: NO secret in the (public) repo. The Claude login lives ONLY in the
# `claude_home` named volume — log in once via
# `docker exec -it claude-api-superset claude`. Both the front's `claude -p`
# and interactive use share that persisted ~/.claude. No metered API key.
#
# Tunables are data-driven from build.json `runtime` (rule 6 — no hardcoded data
# in the engine), so changing the model / concurrency / compression is a JSON edit.
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  rt   = buildJson.runtime or {};
  hr   = rt.headroom or {};
  svc  = container.services or {};
  # WG IP from cloud-data (same source as kg-bridge/cgc). Falls back to oci-apps WG IP.
  wgIp = svc."claude-api-superset".ip or svc."kg-bridge".ip or "10.0.0.6";
  home = "/home/appuser";
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    claude-api-superset = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      # Two long-running procs (Node front + Python compress sidecar) supervised
      # by start.sh. tini (compose-defaults init:true) is PID1 to reap the many
      # short-lived `claude -p` children.
      environment = {
        HOME                   = home;
        # Node front (OpenAI /v1 + Ollama /api + Anthropic /v1/messages → claude CLI)
        BRIDGE_PORT            = toString buildJson.ports.app;
        BRIDGE_BIND            = wgIp;
        BRIDGE_OLLAMA_PORT     = toString buildJson.ports.ollama;
        BRIDGE_OLLAMA_BIND     = wgIp;
        BRIDGE_DEFAULT_MODEL   = rt.model or "claude-sonnet-4-6";
        BRIDGE_MAX_CONCURRENCY = toString (rt.max_concurrency or 12);
        BRIDGE_CALL_TIMEOUT_MS = toString (rt.call_timeout_ms or 180000);
        # Compress hop → Python sidecar (vendored Headroom `compress()`).
        # WG-ONLY, fail-closed: the sidecar binds the WireGuard IP (NOT 0.0.0.0 —
        # with host networking 0.0.0.0 would expose /dashboard + /compress on the
        # PUBLIC NIC). Node reaches it at the same wgIp; the helper/tray reaches
        # /dashboard over the WG mesh. Nothing here is ever publicly reachable.
        HEADROOM_ENABLED       = if (hr.enabled or true) then "1" else "0";
        HEADROOM_HOST          = wgIp;
        HEADROOM_BIND          = wgIp;
        HEADROOM_PORT          = toString buildJson.ports.headroom;
        HEADROOM_SAVINGS_PROFILE   = hr.savings_profile or "agent-90";
        HEADROOM_MIN_TOKENS        = toString (hr.min_tokens_to_compress or 250);
        # Durable savings ledger (Headroom convention) lives in the volume.
        HEADROOM_WORKSPACE_DIR = "${home}/.headroom";
      };
      # Persist home: ~/.claude/.credentials.json (login), ~/.claude.json, and
      # ~/.headroom/proxy_savings.json (lifetime savings). Volume initialises from
      # the image dir (appuser-owned via the Dockerfile) so appuser can write.
      volumes = [ "claude_home:${home}" ];
      healthcheck = {
        test = [
          "CMD" "node" "-e"
          "fetch('http://${wgIp}:${toString buildJson.ports.app}/health').catch(()=>process.exit(1))"
        ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "40s";
      };
    };
  };
  # Named volume holding the persisted Claude login + savings — never in git, never public.
  volumes = {
    claude_home = { name = "claude-api-superset-home"; };
  };
}
