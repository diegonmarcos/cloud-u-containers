# compose.nix — docker-compose for hermes-agent.
# ship-cover 2026-08-09T18:40Z — single batched trigger: newest queued run must contain every undeployed oci-apps service (a newer pending run evicts older ones)
# 2026-08-09 (retry 2): re-ship to restore .secrets on oci-apps. The first
# attempt was killed by the 900s wall-clock watchdog (fixed in 8525be4); the
# second was evicted from the ship-oci-apps queue by a later push.
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# WG-ONLY gateway: host network so the container can reach the WireGuard mesh
# (claude-superset-api at 10.0.0.6:3117) and make outbound Telegram egress
# without NAT hairpin issues. public:false, no Caddy route, no published port.
#
# HERMES API SERVER (loopback only). `gateway run` also starts Hermes'
# OpenAI-compatible API platform whenever API_SERVER_KEY is set: measured
# 2026-10-10 it was already answering on 127.0.0.1:8642 (Hermes 0.21.5), keyed
# from an .env inside the hermes-agent-data volume that no file in this repo
# declared. Its host and port are declared here now, so the listener can never
# drift onto the WireGuard or public interface: API_SERVER_HOST is pinned to
# 127.0.0.1 and the port is build.json ports.api. The only caller is the fleet
# agent gateway my-ai-api (same host, host network), which reaches the REAL
# agent — skills, memory, sessions, toolsets, scheduled jobs — with
# X-Agent-Mode: hermes once it holds the same key as HERMES_API_KEY. The key
# itself belongs in src/secrets.yaml as API_SERVER_KEY (and in my-ai-api's as
# HERMES_API_KEY): a sops edit that needs the fleet age key.
#
# AUTH: secrets delivered via .secrets env_file (sops-encrypted src/secrets.yaml
# → dist/.secrets at deploy). Contains TELEGRAM_BOT_TOKEN, OPENAI_API_KEY
# (pointed at claude-superset-api), and MATTERMOST_TOKEN.
#
# Tunables are data-driven from build.json `runtime` (no hardcoded data in the
# engine): changing the model or backend_url is a JSON edit.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  rt  = buildJson.runtime or {};
in
{
  services = {
    hermes-agent = {
      # Mirrored from docker.io/nousresearch/hermes-agent by the
      # "Mirror hermes-agent image" workflow. GHCR pull is authenticated + fast;
      # Docker Hub anonymous pulls are rate-limited and stall the ship's SSH
      # compose window on this ~900MB image (exit 255, nothing cached).
      #
      # STAGED REPOINT (2026-09-16, step 2 of 2 — DONE). build.json declares
      # upstream_image + docker.runtime_packages.apt, so the engine's Type-B path
      # builds a derived image (FROM that mirror + the agent toolbelt) and
      # publishes it here. Step 1 deliberately kept this line on the bare mirror
      # because the derived package did not exist yet and the pull would have
      # taken hermes down. Ship run 35122459534 published
      # ghcr.io/diegonmarcos/hermes-agent-binaries:latest (tags dfdcc793c9aa,
      # latest) at 2026-09-16T16:37:00Z, so the tag is now confirmed and this
      # points at the derived image — the vaultwarden pattern
      # (user-vault_vaultwarden/src/compose.nix). The toolbelt (jq, ripgrep,
      # wget, unzip, netcat-openbsd, patch, yq, procps, less) is no longer built
      # but unused: it is what the container actually runs.
      image          = "ghcr.io/diegonmarcos/hermes-agent-binaries:latest";
      container_name = app.container_name;
      # host networking: reach WG mesh (10.0.0.6) + outbound Telegram without NAT.
      network_mode   = "host";
      command        = [ "gateway" "run" ];
      # Override the fleet default init:true — the nousresearch/hermes-agent image
      # runs s6-overlay, which aborts ("s6-overlay-suexec: can only run as pid 1")
      # when Docker's tini is injected as PID 1. s6 must be PID 1, so disable init.
      init           = false;
      # Secrets: TELEGRAM_BOT_TOKEN, OPENAI_API_KEY, MATTERMOST_TOKEN.
      env_file       = [ "./.secrets" ];
      environment    = {
        # 10001:999, not the image default 10000:10000, because the shared git tree
        # mounted at /opt/data/git is owned 10001:999 mode 0755 — group 999 gets r-x
        # only, so joining the group grants nothing and ONLY uid 10001 can write.
        # At 10000 hermes could read the tree and commit nothing: measured 2026-09-16,
        # its own sandbox returned uid=10000 and TOUCH_DENIED, and the run then
        # reported a commit sha that does not exist.
        #
        # Safe against stage2-hook.sh's boot chown: it remaps via usermod/groupmod
        # FIRST, then recursively chowns only its own subdir list (cron sessions logs
        # hooks memories skills skins plans workspace home profiles pairing
        # platforms/pairing lazy-packages) — `git` is not in it, so the shared tree is
        # never touched. $HERMES_HOME itself gets a non-recursive chown to 10001:999.
        HERMES_UID           = "10001";
        HERMES_GID           = "999";
        TZ                   = buildJson.timezone or "Europe/Berlin";
        TELEGRAM_ALLOWED_USERS = "6431508617";
        # Point the OpenAI-compat client at claude-superset-api over WG.
        OPENAI_BASE_URL      = rt.backend_url or "http://10.0.0.6:3117/v1";
        # No `or` fallback: a default naming a different model is a second model
        # declaration, and "claude-sonnet-4-6" is not what build.json declares. If
        # runtime.model ever goes missing, eval must fail here rather than quietly
        # run a model nobody asked for.
        OPENAI_MODEL         = rt.model;
        # The API server platform: loopback only, on the declared port (see the
        # header). Hermes' own default host is also 127.0.0.1; pinning it here
        # makes that a declaration rather than an upstream default.
        API_SERVER_HOST      = "127.0.0.1";
        API_SERVER_PORT      = toString buildJson.ports.api;
      };
      volumes = [
        "hermes_data:/opt/data"
        # Declarative config overlay (read-only); operator writes configs/config.yaml.
        # WARNING: this mount source is dist/configs/config.yaml, emitted by
        # flake.nix's `templates` list. If flake.nix ever stops emitting it,
        # the source path won't exist on the VM and Docker silently creates
        # an EMPTY DIRECTORY at ./configs/config.yaml instead of failing —
        # hermes then falls back to env vars only and the ENTIRE config file
        # (dm_topics, require_mention, extra.allow_from/group_allow_from, the
        # lean toolset profile, reactions, rich_messages) is silently
        # disabled with no error anywhere. This exact failure happened on
        # oci-apps (found 2026-08-09): flake.nix had `templates = [];` so
        # dist/ never contained a configs/ directory at all. Keep flake.nix
        # emitting this file.
        "./configs/config.yaml:/opt/data/config.yaml:ro"
        # #764 Jev tool-selection gate, emitted by flake.nix from _shared/jev-gate
        # and enabled by config.yaml's plugins.enabled. Same silent-empty-dir
        # caveat as above if flake.nix ever stops emitting it.
        "./configs/plugins/jev-gate:/opt/data/plugins/jev-gate:ro"
      ];
      # NO healthcheck: the API server's /health only exists while
      # API_SERVER_KEY is set, and the gateway must not be marked unhealthy
      # (and Telegram restarted) for a key that is not wired yet. The fleet
      # gateway probes it instead and reports it in /health.modes[hermes].
    };
  };

  # Named volume for persistent agent memory, conversation history, and state.
  volumes = {
    hermes_data = { name = "hermes-agent-data"; };
  };
}
