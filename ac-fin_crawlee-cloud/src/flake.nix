{
  description = "Crawlee Cloud — Self-hosted Apify-compatible scraping platform (dist layout v2, flake as orchestrator)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    crawlee-src = {
      url = "github:crawlee-cloud/crawlee-cloud";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crawlee-src }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Primary container (api) — engine treats this as the canonical
    # container. Sidecar containers (runner/dashboard/scheduler/db/
    # redis/minio) are declared in compose.nix from buildJson.containers.
    container = builtins.fromJSON (builtins.readFile ./build-crawlee_api.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      # ── Patched upstream source tree ─────────────────────────────
      # The upstream crawlee-cloud repo is patched to:
      #   1. Add @fastify/swagger + swagger-ui deps to packages/api
      #   2. Register OpenAPI spec generation in packages/api/src/index.ts
      #   3. Switch Dockerfile.api from `npm ci` → `npm install` (lockfile
      #      doesn't track the new swagger deps)
      # Output is a directory named "repo" that docker-compose uses as
      # the build context for api/runner/dashboard/scheduler.
      patchedRepo = pkgs.runCommand "repo" {
        nativeBuildInputs = [ pkgs.jq ];
      } ''
        mkdir -p $out
        cp -r ${crawlee-src}/. $out/
        chmod -R u+w $out

        # ── Patch: add @fastify/swagger for OpenAPI spec generation ──

        # 1. Add swagger deps to packages/api/package.json
        jq '.dependencies["@fastify/swagger"] = "^9.4.0" | .dependencies["@fastify/swagger-ui"] = "^5.2.0"' \
          $out/packages/api/package.json > $out/packages/api/package.json.tmp
        mv $out/packages/api/package.json.tmp $out/packages/api/package.json

        # 2. Patch index.ts — add swagger imports and registration after cors
        sed -i "s|import cors from '@fastify/cors';|import cors from '@fastify/cors';\nimport swagger from '@fastify/swagger';\nimport swaggerUi from '@fastify/swagger-ui';|" \
          $out/packages/api/src/index.ts

        sed -i "/await app.register(cors, { origin: true });/a\\
\\
// OpenAPI spec generation\\
await app.register(swagger, {\\
  openapi: {\\
    info: {\\
      title: 'Crawlee Cloud API',\\
      version: '1.0.0',\\
      description: 'Self-hosted Apify-compatible web scraping platform — actors, runs, datasets, key-value stores, and request queues.',\\
    },\\
    tags: [\\
      { name: 'Actors', description: 'Actor management and execution' },\\
      { name: 'Runs', description: 'Actor run status and lifecycle' },\\
      { name: 'Datasets', description: 'Crawl result datasets' },\\
      { name: 'Key-Value Stores', description: 'Key-value storage' },\\
      { name: 'Request Queues', description: 'URL queue management' },\\
      { name: 'Registry', description: 'Actor registry' },\\
      { name: 'Auth', description: 'Authentication and API keys' },\\
      { name: 'Users', description: 'User management' },\\
    ],\\
  },\\
});\\
await app.register(swaggerUi, { routePrefix: '/docs' });" \
          $out/packages/api/src/index.ts

        # 3. Patch Dockerfile.api — use npm install instead of npm ci
        #    (lockfile won't have new swagger deps, npm ci would fail)
        sed -i 's/npm ci /npm install /g' \
          $out/docker/Dockerfile.api
      '';

      # ── Engine output (v2 dist layout) ───────────────────────────
      engineOut = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Crawlee Cloud — Self-hosted Apify-compatible scraping platform";
      };

    in {
      # The flake's default output wraps engine's v2 dist/ and injects
      # the patched upstream repo into dist/assets/repo/ so compose's
      # build contexts resolve at deploy time. extraAssets in engine
      # supports paths but baseNameOf mangles derivation store names,
      # so we override here to get a clean "repo" asset name.
      default = pkgs.runCommand "${buildJson.name}-dist-v2" {
        passthru = engineOut.passthru or {};
      } ''
        cp -r ${engineOut} $out
        chmod -R u+w $out
        mkdir -p $out/assets
        cp -r ${patchedRepo} $out/assets/repo
        chmod -R u+w $out/assets/repo
      '';
    });
  };
}
