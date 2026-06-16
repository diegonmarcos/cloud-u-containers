# compose.nix — pure attrset describing docker-compose.yml for cloud-cgc-mcp.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# Single service: cloud-cgc-mcp — Code Graph Context MCP server
#   - Own code (Type A) packaged by ship engine via native_build.type=image-wrapper
#   - HTTP + stdio transports; host network so Caddy can reach it at 127.0.0.1:PORT
#   - Reads CONFIG_PATH (points at /data/config.json, with sibling cloud-data/)
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  # WG IP from cloud-data — passed to bindHost() so the listener is confined
  # to the WG mesh on host-network mode. Defensive default in source is
  # 127.0.0.1; we explicitly override to the WG IP here.
  vmIp = svc."cloud-cgc-mcp".ip or "10.0.0.6";
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  # Octocode index wiring (data-driven from build.json.runtime.octocode).
  oct = buildJson.runtime.octocode;
in
{
  services = {
    cloud-cgc-mcp = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        MCP_TRANSPORT  = "http";
        MCP_HTTP_PORT  = toString buildJson.ports.app;
        MCP_HTTP_HOST  = vmIp;
        CONFIG_PATH    = "${buildJson.runtime.data_path}/config.json";
        GIT_ROOT       = buildJson.runtime.git_root;
      };
      volumes = [
        "./data:${buildJson.runtime.data_path}:ro"
        # Read the FastEmbed/GraphRAG index + cloned repos maintained by the Dagu
        # octocode-reindex DAG. GIT_ROOT (=oct.repos_path) makes the MCP's octocode
        # query path match the DAG's index path, so the LanceDB project-hash resolves.
        "${oct.repos_volume}:${oct.repos_path}:ro"
        "${oct.db_volume}:${oct.db_path}:ro"
      ];
      healthcheck = {
        test = [
          "CMD" "node" "-e"
          "fetch('http://${vmIp}:${toString buildJson.ports.app}${app.healthcheck}').catch(()=>process.exit(1))"
        ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "15s";
      };
    };

    # ── One-shot GraphRAG reindexer (profile-gated; never starts on `compose up`) ──
    # Mounts the index + repos volumes RW (the live MCP mounts them :ro) and points
    # octocode's LLM at the WG-only claude-openai-bridge. Runs as root so it can write
    # the appuser-owned db volume and operate on the root-owned repos. Trigger:
    #   docker compose --profile reindex run --rm cloud-cgc-mcp-reindex
    # Measure one repo: append `-e OCTOCODE_REPOS=tools`.
    cloud-cgc-mcp-reindex = {
      image = binariesImage;
      container_name = "cloud-cgc-mcp-reindex";
      profiles = [ "reindex" ];
      network_mode = "host";
      user = "0:0";
      command = [ "sh" "/app/reindex.sh" ];
      restart = "no";
      environment = {
        HOME                = oct.home;
        OCTOCODE_HOME       = oct.home;
        # octocode reads *_API_URL (NOT *_BASE_URL) per provider — both point at the bridge.
        OPENAI_API_URL      = oct.llm.openai_api_url;
        OPENAI_API_KEY      = oct.llm.api_key;
        OLLAMA_API_URL      = oct.llm.ollama_api_url;
        OLLAMA_API_KEY      = oct.llm.api_key;
        OCTOCODE_LLM_MODELS = oct.llm.models;   # ordered providers, fallback in reindex.sh
        BRIDGE_HEALTH_URL   = oct.llm.health_url;
        OCTOCODE_REPOS      = toString oct.index_repos;
        OCTOCODE_REPOS_ROOT = oct.repos_path;
        OCTOCODE_PULL       = "0";
      };
      volumes = [
        "${oct.repos_volume}:${oct.repos_path}"
        "${oct.db_volume}:${oct.db_path}"
      ];
    };
  };
  # External named volumes owned by the Dagu DAG ops_octocode-reindex: it clones the
  # repos into octocode_repos and writes the octocode index into octocode_db, then
  # restarts this container. Mounting them here (read-only) is what makes the daily
  # reindex actually reach the live MCP — previously the container mounted neither, so
  # octocode search hit an empty store regardless of how often the DAG ran.
  # Fixed names (no project prefix) so this matches the raw `docker run -v octocode_db`
  # / `octocode_repos` volumes the DAG creates. NOT `external` on purpose: if the DAG
  # hasn't run yet, compose creates the same-named empty volume and the MCP starts with
  # an empty index (octocode returns nothing — graceful) instead of failing to start.
  # The DAG then populates the same volume and restarts the container.
  volumes = {
    "${oct.repos_volume}" = { name = oct.repos_volume; };
    "${oct.db_volume}" = { name = oct.db_volume; };
  };
}
