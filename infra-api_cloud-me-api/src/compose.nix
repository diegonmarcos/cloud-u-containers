# compose.nix — docker-compose spec for cloud-me-api (Type A, own code, #1079).
#
# Runs on oci-analytics, host network, bound to that VM's wg0 address, next to
# git-proxy-api. Caddy on gcp-proxy reverse-proxies api.diegonmarcos.com/me/*
# here after forward_auth (Authelia bearer or session). The read-only deploy
# keys arrive ONLY through .secrets (sops -> step_secrets -> env_file); clones
# and the key files live on size-capped tmpfs mounts, never on the VM disk.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # oci-analytics wg0 address, from cloud-data once the derive engine has run.
  # The literal is only a safety net so the flake still evaluates on the very
  # first ship, before 9_others has emitted this service's entry — the same
  # fallback c3-public-api uses on this VM. 0.0.0.0 is forbidden by the wg0-only
  # bind policy and 127.0.0.1 is unreachable from Caddy, so neither is an option.
  myIp = svc."cloud-me-api".ip or "10.0.0.4";
  port = toString buildJson.ports.app;
in
{
  services = {
    cloud-me-api = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      # CME_KEY_*_B64 only (one read-only deploy key per repo). Decrypted from
      # src/secrets.yaml by the ship's step_secrets into dist/.secrets — never in
      # this repo in plaintext, never sent to a client.
      env_file = [ ".secrets" ];
      environment = {
        BIND_HOST = myIp;
        PORT = port;
        NODE_ENV = "production";
      };
      volumes = [ ];
      tmpfs = [
        "/data:size=96m,mode=1777"
        "/run/keys:size=1m,mode=0700"
      ];
      healthcheck = {
        # node, not curl: the base image needs no extra package for this, and
        # the probe hits the real bind address (host network + wg0-only bind
        # means there is no localhost listener to cheat against).
        test = [
          "CMD-SHELL"
          ("node -e \"require('http').get('http://${myIp}:${port}/health',"
            + "r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\"")
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
      # Read only what build.json actually declares: reading an absent attribute
      # fails eval with "attribute ... missing", and only mem_reservation is
      # declared fleet-wide today.
      deploy.resources =
           (if buildJson.resources ? mem_limit       then { limits       = { memory = buildJson.resources.mem_limit; };       } else {})
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };
}
