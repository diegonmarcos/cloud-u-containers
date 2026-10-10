# compose.nix — docker-compose for OpenClaw (cloud-agi-openclaw).
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# LOOPBACK-ONLY (hermes-agent / my-ai-api pattern): host network, OpenClaw's
# gateway bound to 127.0.0.1 (openclaw.json gateway.bind = loopback). No port
# is published, no Caddy route, nothing on the WireGuard interface: the fleet
# agent gateway my-ai-api (also host network) is the only caller, and the
# phone reaches it through that gateway (X-Agent-Mode: openclaw).
#
# NO SECRETS. auth mode none is OpenClaw's documented trusted-loopback setup,
# and its model calls go to my-ai-api's OpenAI-compatible face, which injects
# the OpenRouter key itself. So there is no src/secrets.yaml and no env_file.
#
# CONFIG: openclaw-config.nix renders configs/openclaw.json from build.json;
# it is mounted read-only and COPIED into the state volume at every start.
# OpenClaw's startup doctor chmods its config file, which a read-only bind
# mount owned by the deploy user refuses (EPERM fchmod, measured 2026-10-10),
# and OPENCLAW_CONFIG_READONLY=1 makes the same doctor abort the start. A copy
# keeps build.json the one declaration: any runtime edit is gone at the next
# restart.
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  res  = app.resources or {};
  port = toString buildJson.ports.app;
  home = "/home/node";
  state = "${home}/.openclaw";
in
{
  services = {
    openclaw = {
      image          = app.image;
      container_name = app.container_name;
      # An agent runtime the app expects to answer: back after a host reboot
      # or a crash, like cloud-agi-goose (#545), not the fleet default restart:no.
      restart        = "unless-stopped";
      network_mode   = "host";
      env_file       = [];
      # Upstream's ENTRYPOINT (tini → docker-entrypoint.mjs) is replaced so the
      # declared config is installed before the gateway starts; Docker's own
      # init (fleet default init:true) stays PID 1 and reaps.
      entrypoint = [
        "sh" "-c"
        "set -eu; mkdir -p ${state}; cp /etc/openclaw/openclaw.json ${state}/openclaw.json; chmod 600 ${state}/openclaw.json; exec node dist/index.js gateway --bind ${buildJson.runtime.bind} --port ${port}"
      ];
      environment = {
        HOME                     = home;
        OPENCLAW_HOME            = home;
        OPENCLAW_STATE_DIR       = state;
        OPENCLAW_CONFIG_PATH     = "${state}/openclaw.json";
        OPENCLAW_GATEWAY_PORT    = port;
        # mDNS advertising is pointless on loopback and noisy on host network.
        OPENCLAW_DISABLE_BONJOUR = "1";
        # The doctor's own advice for small hosts (printed on the 2026-10-10 smoke run).
        OPENCLAW_NO_RESPAWN      = "1";
        NODE_COMPILE_CACHE       = "${state}/compile-cache";
        TZ                       = buildJson.timezone or "Europe/Berlin";
      };
      volumes = [
        "openclaw_state:${state}"
        "./configs/openclaw.json:/etc/openclaw/openclaw.json:ro"
      ];
      # Upstream's compose drops these two; the agent's tools need neither.
      cap_drop = [ "NET_RAW" "NET_ADMIN" ];
      healthcheck = {
        test = [
          "CMD" "node" "-e"
          "fetch('http://127.0.0.1:${port}/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
        ];
        interval     = "30s";
        timeout      = "5s";
        retries      = 3;
        start_period = "90s";
      };
      deploy.resources =
           (if res ? mem_limit       then { limits       = { memory = res.mem_limit; };       } else {})
        // (if res ? mem_reservation then { reservations = { memory = res.mem_reservation; }; } else {});
    };
  };

  volumes = {
    openclaw_state = { name = "openclaw-state"; };
  };
}
