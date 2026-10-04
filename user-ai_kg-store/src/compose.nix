# compose.nix — pure attrset describing docker-compose.yml for kg-store (SurrealDB).
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  port = toString buildJson.ports.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps them
  # into a GHCR image; at runtime we pull the published binaries image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # ── Memory budget, derived from ONE declared number ──────────────────
  # build.json containers.app.resources.mem_limit is the only place the size
  # is written. It feeds BOTH halves of the fix, and neither half works alone:
  #
  #   cgroup ceiling  deploy.resources.limits.memory -> memory.max
  #   engine budget   SURREAL_ROCKSDB_* -> what RocksDB will actually hold
  #
  # Without the ceiling, SurrealDB sizes its LRU block cache from the memory it
  # can see, which with no cgroup is the whole host:
  #   ROCKSDB_BLOCK_CACHE_SIZE default = max(visible/2 - 1GiB, 16MiB)
  #   (surrealdb v2.3.7, crates/core/src/kvs/rocksdb/cnf.rs:125-143)
  # On oci-apps that is 23.41GiB/2 - 1GiB ≈ 10.7GB — which is, to within
  # rounding, the 10.6GB a restart returned on 2026-09-21.
  #
  # Without the engine budget, the ceiling alone would just turn an unbounded
  # cache into a cgroup OOM kill: the cache is cgroup-aware, but it aims at
  # half the cap and floors at 16MiB, and the memtables (WRITE_BUFFER_SIZE ×
  # MAX_WRITE_BUFFER_NUMBER, default up to 128MiB × 32 = 4GiB) are sized off
  # host RAM tiers independently. So both are declared, explicitly.
  #
  # Budget: cache 1/2 + memtables 2 × 1/8 = 3/4 of the cap, leaving the rest
  # for the process, the WAL and compaction readahead.
  memLimit = app.resources.mem_limit;
  memParts = builtins.match "([0-9]+)([KkMmGg])[iI]?[bB]?" memLimit;
  memBytes =
    if memParts == null
    then throw ("${buildJson.name}: containers.app.resources.mem_limit = "
                + "\"${memLimit}\" is not <integer><K|M|G>[i][B]; the RocksDB "
                + "cache budget is computed from it and cannot be guessed.")
    else (builtins.fromJSON (builtins.elemAt memParts 0)) *
         (let u = builtins.elemAt memParts 1; in
          if      u == "G" || u == "g" then 1073741824
          else if u == "M" || u == "m" then 1048576
          else                              1024);

  blockCacheBytes      = memBytes / 2;
  writeBufferBytes     = memBytes / 8;
  maxWriteBufferNumber = 2;
in
{
  services = {
    surrealdb = {
      image          = binariesImage;
      container_name = app.container_name;
      network_mode   = "host";
      # Always-on data store — override the fleet-wide restart:no default
      # (compose-defaults.json) so a stop/reboot/crash brings it back instead
      # of leaving the knowledge graph dark until someone notices.
      restart        = "unless-stopped";
      # Run as root: the surrealdb image's default non-root user cannot create the
      # RocksDB dir in the root-owned `${data_path}:/data` host bind mount
      # ("PermissionDenied"). Single-tenant, 127.0.0.1-bound file store — same
      # root pattern as the reindex job. Without this the container crash-loops.
      user           = "0:0";
      env_file       = [ ".secrets" ];
      # Names verified against surrealdb v2.3.7 source (cnf.rs), not guessed.
      # BLOCK_CACHE_SIZE and WRITE_BUFFER_SIZE are BYTES.
      environment = {
        SURREAL_ROCKSDB_BLOCK_CACHE_SIZE        = toString blockCacheBytes;
        SURREAL_ROCKSDB_WRITE_BUFFER_SIZE       = toString writeBufferBytes;
        SURREAL_ROCKSDB_MAX_WRITE_BUFFER_NUMBER = toString maxWriteBufferNumber;
      };
      deploy = {
        resources = {
          limits       = { memory = memLimit; };
          reservations = { memory = app.resources.mem_reservation; };
        };
      };
      command =
        "start --log info --user root --pass \${SURREAL_ROOT_PASSWORD} "
        + "--bind 127.0.0.1:${port} file:/data/surreal.db";
      volumes = [ "${buildJson.data_path}:/data" ];
      healthcheck = {
        test         = [ "CMD" "/surreal" "is-ready" "--conn" "http://localhost:${port}" ];
        interval     = "15s";
        timeout      = "15s";
        retries      = 5;
        start_period = "30s";
      };
    };
  };
}
