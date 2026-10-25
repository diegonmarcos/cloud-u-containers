# compose.nix — embeddings-api: Infinity (embeddings + rerank) plus /pdf, one container.
#   - Own code (Type A), packaged by the ship engine (native_build.type=image-wrapper).
#   - Published on oci-apps' WireGuard address only (mesh direct-dial rule, #1104): the phone and the
#     other VMs dial http://embeddings-api.mesh.diegonmarcos.com:7997, never a public address.
#   - CPU torch; models are downloaded on first start into a named volume and kept across redeploys.
#   - restart unless-stopped so a host reboot brings it back; the memory cap keeps a model spike off
#     the neighbours (about 5 GB resident for both models).
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  port = toString buildJson.ports.app;
  bind = buildJson.runtime.wg_bind or "10.0.0.6";
  m    = buildJson.models;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    embeddings-api = {
      image          = binariesImage;
      container_name = app.container_name;
      restart        = "unless-stopped";
      env_file       = [];
      environment = {
        EMBED_MODEL  = m.embed;
        RERANK_MODEL = m.rerank;
        BATCH_SIZE   = toString m.batch_size;
        # No analytics from a private fleet service.
        INFINITY_ANONYMOUS_USAGE_STATS = "0";
        HF_HUB_DISABLE_TELEMETRY       = "1";
        OMP_NUM_THREADS                = "4";
      };
      ports   = [ "${bind}:${port}:${port}" ];
      volumes = app.volumes;
      healthcheck = {
        test = [ "CMD" "python3" "-c" "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${port}/health', timeout=8)" ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 5;
        # First start downloads about 4.6 GB of weights before the server listens.
        start_period = "900s";
      };
      deploy.resources =
           (if buildJson.resources ? mem_limit       then { limits       = { memory = buildJson.resources.mem_limit; };       } else {})
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };
  volumes = {
    embeddings_api_hf = {};
  };
}
