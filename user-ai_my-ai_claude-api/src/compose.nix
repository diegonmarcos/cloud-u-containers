# compose.nix — docker-compose for my-ai_claude-api (formerly claude-superset-api).
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# WG-ONLY sidecar (inherited from kg-bridge): host network, listeners bound to the
# VM's WireGuard IP (10.0.0.6) — reachable only across the WG mesh, NEVER the public
# NIC. No Caddy route, no published port, public:false. Callers (octocode/cgc, the
# desktop/termux fallback client) reach it at <wg-ip>:PORT over WG.
#
# AUTH: NO secret in the (public) repo. The Claude login lives ONLY in the
# `claude_home` named volume — log in once via
# `docker exec -it my-ai_claude-api claude`. Both the front's `claude -p`
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
  # New name first; the pre-rename key stays as a fallback so this keeps resolving
  # on any consolidated config generated before the 2026-09-05 rebrand.
  wgIp = svc."my-ai_claude-api".ip or svc."claude-superset-api".ip
         or svc."kg-bridge".ip or "10.0.0.6";
  home = "/home/appuser";
  # HARDCODED, NOT derived from buildJson.name — deliberate, do not "fix".
  # This service was renamed claude-superset-api -> my-ai_claude-api on 2026-09-05,
  # but the GHCR image path was deliberately NOT renamed: package visibility on GHCR
  # is fixed AT CREATION and there is no API to flip it afterwards. Pushing under a
  # new name creates a brand-new package that is born PRIVATE, and the VM's pull is
  # then denied — which is exactly the state session-memory and matrix-mautrix-whatsapp
  # are stuck in today. Interpolating buildJson.name here would have silently done
  # that on the first deploy after the rename. Keep this literal in sync with
  # build.json `docker.image` (also still claude-superset-api); the ship engine
  # appends `-binaries` to that field when it pushes.
  binariesImage = "ghcr.io/diegonmarcos/claude-superset-api-binaries:latest";
in
{
  services = {
    my-ai_claude-api = {
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
        # Requested-id → claude model id map (JSON). Lets callers pick a cheaper
        # tier per request (cgc indexing → haiku); unknown ids → BRIDGE_DEFAULT_MODEL.
        BRIDGE_MODEL_ALIASES   = builtins.toJSON (rt.model_aliases or { });
        BRIDGE_MAX_CONCURRENCY = toString (rt.max_concurrency or 12);
        BRIDGE_CALL_TIMEOUT_MS = toString (rt.call_timeout_ms or 180000);
        # Cross-device session store (WG-only), persisted in the claude_home volume.
        BRIDGE_SESSIONS_DIR    = "${home}/${(rt.sessions.dir or ".claude-sessions")}";
        BRIDGE_SESSIONS_KEEP   = toString ((rt.sessions.keep or 20));
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
        # Headroom proxy face — compress-and-forward to Anthropic with the
        # CLIENT's own creds (transparent), so `ANTHROPIC_BASE_URL=<this> claude`
        # gets full interactive/multi-turn compression. WG-bound, fail-closed.
        HEADROOM_PROXY_ENABLED = if (hr.proxy_enabled or true) then "1" else "0";
        HEADROOM_PROXY_PORT    = toString (buildJson.ports.proxy or 8789);
        HEADROOM_PROXY_BIND    = wgIp;
        HEADROOM_PROXY_BACKEND = hr.proxy_backend or "anthropic";
        # Durable savings ledger (Headroom convention) lives in the volume.
        HEADROOM_WORKSPACE_DIR = "${home}/.headroom";
      };
      # Secrets: sops src/secrets.yaml -> dist/.secrets (rsynced beside this
      # compose.yml at deploy). Delivers AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN, the
      # bearer for the HTTP MCP servers rendered by start.sh into ~/.claude.json.
      env_file = [ "./.secrets" ];
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
    # HARDCODED to the pre-rename name, deliberately — do not "fix" to match the
    # service name. This volume holds the ONLY copy of the Claude subscription
    # login (~/.claude/.credentials.json), ~/.claude.json, the cross-device
    # session store and the lifetime Headroom savings ledger. Renaming it does not
    # move the data: compose would create a fresh EMPTY volume and the service
    # would come up logged out, with the savings ledger reset to zero.
    # oci-apps still carries claude-api-superset-home and claude-openai-bridge-home
    # — two volumes orphaned by exactly this mistake during earlier renames of this
    # same service. Renaming this is a live data migration, not a rename.
    claude_home = { name = "claude-superset-api-home"; };
  };
}
