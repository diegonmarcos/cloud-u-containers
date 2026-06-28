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
  # Single GHCR upstream for the octocode DB (producer = cloud-cgc-db-update.sh).
  # The db-restore init below pulls this and populates octocode_db on every deploy.
  dbImage = "${buildJson.db_publish.image}:${buildJson.db_publish.tag or "latest"}";
  # Octocode index wiring (data-driven from build.json.runtime.octocode).
  oct = buildJson.runtime.octocode;
  # Shared body for the one-shot octocode jobs. Two profile-gated variants below
  # differ ONLY in OCTOCODE_CLEAR: `index` = incremental (git-aware, changed files
  # only), `reindex` = forced fresh build (octocode clear + index) that re-runs the
  # GraphRAG AI phase (description/relationship LLM calls).
  octocodeJob = {
    image = binariesImage;
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
      # kg-store (SurrealDB) ingest — reindex.sh mirrors octocode's full file-level
      # code graph (octocode-export.py → kg-ingest.mjs) per repo, then loads the infra
      # graph delta. Data-driven. KG_STORE_PASS is delivered via env_file ".secrets"
      # below (sops src/secrets.yaml → build.sh secrets → .secrets); kg-ingest.mjs
      # no-ops if it's unset, so this stays safe when secrets aren't decrypted.
      KG_STORE_URL        = oct.kg_store.url;
      KG_STORE_NS         = oct.kg_store.ns;
      KG_STORE_DB         = oct.kg_store.db;
      KG_STORE_USER       = oct.kg_store.user;
      KG_DELTA            = oct.kg_store.delta;
      KG_GRAPHS_DIR       = "/app/graphs";
    };
    env_file = [ ".secrets" ];
    volumes = [
      "${oct.repos_volume}:${oct.repos_path}"
      "${oct.db_volume}:${oct.db_path}"
    ];
  };
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
        # kg-store SurrealDB — exposed to MCP clients via the cgc.kgstore.* tools
        # (read-only query of the unified code+infra graph). KG_STORE_PASS arrives
        # via env_file ".secrets" below.
        KG_STORE_URL   = oct.kg_store.url;
        KG_STORE_NS    = oct.kg_store.ns;
        KG_STORE_DB    = oct.kg_store.db;
        KG_STORE_USER  = oct.kg_store.user;
      };
      env_file = [ ".secrets" ];
      # Self-heal: wait for the octocode_db volume to be restored from GHCR before
      # serving, so a cold/redeploy never comes up on an empty/stale index.
      depends_on = {
        cloud-cgc-mcp-db-restore = { condition = "service_completed_successfully"; };
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

    # ── DB restore (autodeploy self-heal) ───────────────────────────────────────
    # Pull the GHCR DB image and populate the octocode_db volume BEFORE the MCP
    # starts → a cold deploy / redeploy serves the CURRENT upstream DB instead of an
    # empty or stale volume. GHCR is the single upstream (producer
    # cloud-cgc-db-update.sh). Runs on every `compose up` (NOT profile-gated),
    # idempotent, data-driven image. The DB tar is arch-independent, so the arm64
    # busybox base is irrelevant — only its /octocode-db payload is copied.
    cloud-cgc-mcp-db-restore = {
      image = dbImage;
      container_name = "cloud-cgc-mcp-db-restore";
      restart = "no";
      volumes = [ "${oct.db_volume}:${oct.db_path}" ];
      entrypoint = [ "sh" "-c" ''
        set -e
        d="${oct.db_path}"
        mkdir -p "$d"
        rm -rf "$d"/* "$d"/.[!.]* 2>/dev/null || true
        cp -a /octocode-db/. "$d"/
        echo "[db-restore] populated ${oct.db_volume} from ${dbImage}"
      '' ];
    };

    # ── One-shot octocode jobs (profile-gated; never start on `compose up`) ──────
    # Both mount index+repos RW (live MCP mounts them :ro) + run as root. Triggers:
    #   FORCE rebuild (always re-runs GraphRAG LLM):
    #     docker compose --profile reindex run --rm cloud-cgc-mcp-reindex
    #   INCREMENTAL (git-aware, only changed files):
    #     docker compose --profile index run --rm cloud-cgc-mcp-index
    #   Scope one repo: append `-e OCTOCODE_REPOS=tools`.
    cloud-cgc-mcp-reindex = octocodeJob // {
      container_name = "cloud-cgc-mcp-reindex";
      profiles = [ "reindex" ];
      environment = octocodeJob.environment // { OCTOCODE_CLEAR = "1"; };
    };
    cloud-cgc-mcp-index = octocodeJob // {
      container_name = "cloud-cgc-mcp-index";
      profiles = [ "index" ];
      environment = octocodeJob.environment // { OCTOCODE_CLEAR = "0"; };
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
