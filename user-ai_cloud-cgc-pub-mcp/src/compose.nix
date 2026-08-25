# compose.nix — pure attrset describing docker-compose.yml for cloud-cgc-pub-mcp.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# Single service: cloud-cgc-pub-mcp — Code Graph Context MCP server
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
  vmIp = svc."cloud-cgc-pub-mcp".ip or "10.0.0.6";
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  # Single GHCR upstream for the octocode DB (producer = cloud-cgc-db-update.sh).
  # The db-restore init below pulls this and populates octocode_db on every deploy.
  dbImage = "${buildJson.db_publish.image}:${buildJson.db_publish.tag or "latest"}";
  # Matrix-producer upstream (base + one image per repo — see
  # cloud-cgc-db-restore-all.sh). Read here, at Nix eval time, so the restore
  # container never needs its own build.json/jq access at runtime (it has no
  # repo checkout, same reasoning as cloud-cgc-db-restore.sh's env-first
  # design). db_publish above stays the default until cutover — see
  # cloud-cgc-pub-mcp-db-restore-multi below.
  perRepo = buildJson.per_repo_publish or { };
  perRepoImagePrefix = perRepo.image_prefix or "ghcr.io/diegonmarcos/cgc-db-";
  perRepoTag = perRepo.tag or "latest";
  perRepoBaseImage = perRepo.base_image or "${perRepoImagePrefix}base:${perRepoTag}";
  # docker-compose does its OWN `$`-interpolation on every string in the rendered
  # compose file — including text spliced in via builtins.readFile — and errors
  # ("invalid interpolation format") on anything that isn't `$VAR` / `${VAR}` /
  # `${VAR:-default}` (e.g. a raw script's `$1`, `$#`, `$((...))`, `$_e`). Doubling
  # every literal `$` to `$$` here makes compose collapse it back to a single `$`
  # for the in-container shell — same $-escaping class as escape_dollars for
  # secrets, same convention already used for hand-written shell elsewhere in this
  # repo's compose.nix files (infra-db_redis, infra-obs_dbgate, infra-sec_authelia,
  # user-comm_snappymail); this just applies it to a builtins.readFile'd script
  # instead of hand-doubling each `$` in the Nix source.
  escapeDollars = builtins.replaceStrings [ "$" ] [ "$$" ];
  # Octocode index wiring (data-driven from build.json.runtime.octocode).
  oct = buildJson.runtime.octocode;

  # ── Private MCP surface (cloud-cgc-pvt-mcp) ────────────────────────────────
  # Read from build.json, not hardcoded here: the port has to be in the port
  # registry the derive pipeline builds from `ports`, and the volume name has to
  # be the same string the restore writes to. Two literals in two files is how
  # you end up with a private MCP serving an empty volume and nobody noticing.
  pvtName     = buildJson.containers.pvt.container_name;
  pvtPort     = buildJson.ports.pvt;
  pvtDbVolume = oct.pvt_db_volume;
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
      # octocode >=0.22 caches fastembed models under $XDG_CACHE_HOME/octolib/fastembed;
      # keep them inside the DB volume, where the base image restores them.
      XDG_CACHE_HOME      = "${oct.db_path}/fastembed";
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
      # Deny list for reindex.sh's own runtime guard (see there): repos that must never
      # be indexed into the shared /repos volume (e.g. cloud-vault, the credential
      # store). Same data-driven mechanism as OCTOCODE_REPOS above — the derive-time
      # check in derive-repo-map.ts only validates the STATIC index_repos, so this is
      # what catches a per-run `-e OCTOCODE_REPOS=<repo>` override (documented below).
      SYNC_EXCLUDE        = toString (builtins.attrNames (oct.sync_exclude or { }));
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
  # ── The MCP service itself, parameterized ──────────────────────────────────
  # Public and private are the SAME container: same image, same code, same 48
  # tools. What separates them is the DB VOLUME each is pointed at — octocode
  # can only answer about the LanceDB tree it can see, so "the private repos'
  # DBs are simply not in the public volume" is the whole isolation mechanism.
  # That is deliberately stronger than a tool-subset flag: there is no code path
  # on the public surface that could leak cloud-data, because the data is not
  # there to leak. Three values differ; everything else is identical by
  # construction rather than by two definitions someone has to keep in sync.
  mcpService = { containerName, port, dbVolume }: {
    image = binariesImage;
    container_name = containerName;
    network_mode = "host";
    environment = {
      MCP_TRANSPORT  = "http";
      MCP_HTTP_PORT  = toString port;
      MCP_HTTP_HOST  = vmIp;
      CONFIG_PATH    = "${buildJson.runtime.data_path}/config.json";
      GIT_ROOT       = buildJson.runtime.git_root;
      # octocode >=0.22 caches fastembed models under $XDG_CACHE_HOME/octolib/fastembed;
      # the restored base image carries them at <db_path>/fastembed — no download at first query.
      XDG_CACHE_HOME = "${oct.db_path}/fastembed";
      # kg-store SurrealDB — exposed to MCP clients via the cgc.kgstore.* tools
      # (read-only query of the unified code+infra graph). KG_STORE_PASS arrives
      # via env_file ".secrets" below.
      KG_STORE_URL   = oct.kg_store.url;
      KG_STORE_NS    = oct.kg_store.ns;
      KG_STORE_DB    = oct.kg_store.db;
      KG_STORE_USER  = oct.kg_store.user;
    };
    env_file = [ ".secrets" ];
    volumes = [
      "./data:${buildJson.runtime.data_path}:ro"
      # Read the FastEmbed/GraphRAG index + cloned repos maintained by the Dagu
      # octocode-reindex DAG. GIT_ROOT (=oct.repos_path) makes the MCP's octocode
      # query path match the DAG's index path, so the LanceDB project-hash resolves.
      "${oct.repos_volume}:${oct.repos_path}:ro"
      # NOT :ro, however much we would like it to be. `octocode search` and
      # `octocode graphrag` open the queried repo's LanceDB project dir
      # read-write even for a pure read, so with a :ro mount EVERY tool call
      # died with "Error: Read-only file system (os error 30)" the moment it
      # had a real repo as its CWD. Measured both ways on oci-apps:
      #   :ro + cd /repos/cloud-infra -> os error 30
      #   rw  + cd /repos/cloud-infra -> query runs
      # The repos mount above stays :ro — that one octocode never writes to.
      # Drift is not a worry: this volume is disposable, rebuilt wholesale by
      # cloud-cgc-db-restore-all.sh from the per-repo GHCR images.
      "${dbVolume}:${oct.db_path}"
    ];
    healthcheck = {
      test = [
        "CMD" "node" "-e"
        "fetch('http://${vmIp}:${toString port}${app.healthcheck}').catch(()=>process.exit(1))"
      ];
      interval     = "30s";
      timeout      = "10s";
      retries      = 3;
      start_period = "15s";
    };
  };

  # ── Multi-image DB restore, parameterized ──────────────────────────────────
  # One definition, two targets. The public restore filters the private repos
  # out (CGC_INCLUDE_PRIVATE=0 + CGC_PRIVATE_REPOS); the private one takes the
  # lot. Splitting these into two hand-written services is how the two would
  # drift until one day the public one stopped filtering.
  restoreMultiService = { containerName, profile, targetVolume, includePrivate }: {
    image = "docker:cli";
    container_name = containerName;
    profiles = [ profile ];
    restart = "no";
    # Host networking, exactly like the app and octocodeJob above. This service
    # runs `docker manifest inspect` INSIDE the container, and that is a CLI-side
    # registry call made over the CONTAINER's network namespace — unlike `docker
    # pull`, which the daemon performs on the host and which therefore worked
    # fine here all along. On a compose bridge network Docker forces its embedded
    # resolver at 127.0.0.11, which forwards to the configured dns
    # [10.0.0.1, 1.1.1.1]; 10.0.0.1 is the WireGuard mesh resolver and is not
    # routable from a bridge namespace, so every lookup stalls:
    #   lookup ghcr.io on 127.0.0.11:53: i/o timeout
    # restore-all.sh discards that probe's stderr, so it surfaced as the deeply
    # misleading "base image not found on GHCR" and aborted the entire restore
    # on a box that pulls from ghcr.io all day. Do not drop this back to bridge:
    # the app escapes the bug only because it is host-networked too.
    network_mode = "host";
    environment = {
      CGC_DB_IMAGE_PREFIX = perRepoImagePrefix;
      CGC_DB_BASE_IMAGE = perRepoBaseImage;
      CGC_DB_TAG = perRepoTag;
      CGC_INDEX_REPOS = toString oct.index_repos;
      # This container has no build.json, so the private list cannot be read
      # from there — pass it explicitly. Without it the restore's public/private
      # filter has nothing to filter on and a private repo's DB would be
      # extracted into the volume the PUBLIC MCP serves. Today a second guard
      # also holds (oci-apps has no ghcr.io credentials, so a private package
      # is unpullable there), but that one is invisible and one `docker login`
      # away from gone; this is the declared one.
      CGC_PRIVATE_REPOS = toString oct.private_repos;
      # The name of the PUBLIC volume, passed unconditionally. This container has
      # no build.json, so the CGC_INCLUDE_PRIVATE guard in
      # cloud-cgc-db-restore-all.sh cannot look it up and — by design — refuses
      # rather than guessing. Passing it here is what lets the private restore
      # prove it is not writing into the volume the public MCP serves.
      CGC_PUBLIC_DB_VOLUME = oct.db_volume;
      CGC_INCLUDE_PRIVATE = includePrivate;
      CGC_DB_TARGET_VOLUME = targetVolume;
      # The uid:gid cloud-cgc-pub-mcp runs as — the binaries image's USER
      # (appuser). The restore extracts the GHCR images as whoever invoked it
      # (root here, uid 1001 over the oci-apps SSH path), so without this the
      # DB lands owned by the wrong user and octocode dies with "Permission
      # denied (os error 13)" — it opens the queried project dir read-write.
      CGC_DB_OWNER = "10001:999";
    };
    volumes = [ "/var/run/docker.sock:/var/run/docker.sock" ];
    entrypoint = [ "sh" "-c" ''
      cat > /tmp/cloud-cgc-db-restore-all.sh <<'CGC_RESTORE_ALL_EOF_9f3a1b'
      ${escapeDollars (builtins.readFile ../../../1_cicd/src/ops/cloud-cgc-db-restore-all.sh)}
      CGC_RESTORE_ALL_EOF_9f3a1b
      sh /tmp/cloud-cgc-db-restore-all.sh
    '' ];
  };

in
{
  services = {
    cloud-cgc-pub-mcp = mcpService {
      containerName = app.container_name;
      port          = buildJson.ports.app;
      dbVolume      = oct.db_volume;
    };

    # ── Private surface (mesh-only) ────────────────────────────────────────────
    # No Caddy route, no DNS record, no public port: host-networked on the WG IP,
    # so it answers at ${vmIp}:${toString pvtPort} from inside the mesh and is
    # unreachable from anywhere else. That is why build.json declares it
    # public=false / proxy=null — a private index must not acquire a public
    # hostname by accident the way an app_hub entry would give it one.
    ${pvtName} = mcpService {
      containerName = pvtName;
      port          = pvtPort;
      dbVolume      = pvtDbVolume;
    };

    # ── DB restore (profile-gated; NOT auto-started) ────────────────────────────
    # Profile-gated because the octocode-db image is built amd64-only by the x86
    # GHA runner; running it on arm64 oci-apps produces "exec format error".
    # The octocode_db volume is populated externally (Dagu DAG / cgc-db GHA).
    # Explicit opt-in: docker compose --profile restore run --rm cloud-cgc-pub-mcp-db-restore
    cloud-cgc-pub-mcp-db-restore = {
      image = dbImage;
      container_name = "cloud-cgc-pub-mcp-db-restore";
      profiles = [ "restore" ];
      restart = "no";
      volumes = [ "${oct.db_volume}:${oct.db_path}" ];
      # Use Nix-interpolated LITERAL paths, never a shell variable: docker compose
      # interprets `$d` / `${d}` in the compose file as ITS OWN interpolation and
      # expands them to empty before the container runs (proven: mkdir got "") — the
      # same `$`-eating class as escape_dollars. The literal path has no `$`, so
      # compose passes it through untouched.
      entrypoint = [ "sh" "-c" ''
        set -e
        mkdir -p "${oct.db_path}"
        rm -rf "${oct.db_path}"/* "${oct.db_path}"/.[!.]* 2>/dev/null || true
        cp -a /octocode-db/. "${oct.db_path}"/
        echo "[db-restore] populated ${oct.db_volume} from ${dbImage}"
      '' ];
    };

    # ── DB restore — MULTI-IMAGE (matrix producer: base + one image per repo,
    # cloud-cgc-db-restore-all.sh — Task 4). Same opt-in shape as the monolith
    # restore above: docker compose --profile restore-multi run --rm
    # cloud-cgc-pub-mcp-db-restore-multi. NOT the default — the monolith service
    # above stays it until the matrix producer (cgc-db-index.yml) is proven
    # green, per the migration plan.
    #
    # This container has no repo checkout (remote_path is just the compose
    # project dir, not a cloud-infra clone), so it cannot `docker pull` a
    # per-image builder or exec the ops/ script off disk. Two things solve
    # that without duplicating cloud-cgc-db-restore-all.sh's logic by hand:
    #   · docker:cli — official, has `docker` + `sh`, nothing else needed
    #     (every value below is passed as env, so the script's own build.json
    #     fallback — see its need_bj() — is never exercised here either).
    #   · builtins.readFile embeds the ACTUAL script file's content at Nix
    #     eval time (this repo checkout HAS it, even though the deployed
    #     container won't) — single source of truth stays the ops/ script,
    #     this is just how it reaches a host with no checkout of its own.
    # docker.sock: this talks to the HOST's OWN daemon (same pattern as
    # infra-bld_cloud-builder-x / infra-bld_gha-runner / infra-obs_dagu
    # compose.nix) so `docker pull`/`create`/`cp` reach GHCR through the
    # daemon's already-established login, and CGC_DB_TARGET_VOLUME routes the
    # final swap through a throwaway container instead of a raw host path —
    # this container's own filesystem is otherwise irrelevant to the restore.
    cloud-cgc-pub-mcp-db-restore-multi = restoreMultiService {
      containerName  = "cloud-cgc-pub-mcp-db-restore-multi";
      profile        = "restore-multi";
      targetVolume   = oct.db_volume;
      includePrivate = "0";
    };

    # Same restore, private target. CGC_INCLUDE_PRIVATE=1 disables the
    # public/private filter, and the script REQUIRES it be paired with a
    # CGC_DB_TARGET_VOLUME that is not the public one — see the guard at the top
    # of cloud-cgc-db-restore-all.sh. The pvt volume is a superset: every repo,
    # public and private, so the private surface answers about everything.
    "${pvtName}-db-restore-multi" = restoreMultiService {
      containerName  = "${pvtName}-db-restore-multi";
      profile        = "restore-multi-pvt";
      targetVolume   = pvtDbVolume;
      includePrivate = "1";
    };

    # ── One-shot octocode jobs (profile-gated; never start on `compose up`) ──────
    # Both mount index+repos RW (live MCP mounts them :ro) + run as root. Triggers:
    #   FORCE rebuild (always re-runs GraphRAG LLM):
    #     docker compose --profile reindex run --rm cloud-cgc-pub-mcp-reindex
    #   INCREMENTAL (git-aware, only changed files):
    #     docker compose --profile index run --rm cloud-cgc-pub-mcp-index
    #   Scope one repo: append `-e OCTOCODE_REPOS=cloud-android`. (reindex.sh checks even this
    #   override against SYNC_EXCLUDE above — a denied repo is refused, not indexed.)
    cloud-cgc-pub-mcp-reindex = octocodeJob // {
      container_name = "cloud-cgc-pub-mcp-reindex";
      profiles = [ "reindex" ];
      environment = octocodeJob.environment // { OCTOCODE_CLEAR = "1"; };
    };
    cloud-cgc-pub-mcp-index = octocodeJob // {
      container_name = "cloud-cgc-pub-mcp-index";
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
    # Private surface's own volume. NEVER the same name as db_volume.
    "${pvtDbVolume}" = { name = pvtDbVolume; };
  };
}
