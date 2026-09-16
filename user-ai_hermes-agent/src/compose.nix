# compose.nix — docker-compose for hermes-agent.
# ship-cover 2026-08-09T18:40Z — single batched trigger: newest queued run must contain every undeployed oci-apps service (a newer pending run evicts older ones)
# 2026-08-09 (retry 2): re-ship to restore .secrets on oci-apps. The first
# attempt was killed by the 900s wall-clock watchdog (fixed in 8525be4); the
# second was evicted from the ship-oci-apps queue by a later push.
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# WG-ONLY gateway: host network so the container can reach the WireGuard mesh
# (claude-superset-api at 10.0.0.6:3117) and make outbound Telegram egress
# without NAT hairpin issues. No inbound HTTP port is published — the Hermes
# API server is NOT enabled (command = ["gateway" "run"] only), so there is
# nothing to expose. public:false, no Caddy route.
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
      ];
      # NO healthcheck: the Hermes gateway subcommand exposes no HTTP health
      # endpoint when the API server is disabled (command = "gateway run").
      # Enable once the api-server subcommand is added and a port is opened.
    };
  };

  # Named volume for persistent agent memory, conversation history, and state.
  volumes = {
    hermes_data = { name = "hermes-agent-data"; };
  };
}
