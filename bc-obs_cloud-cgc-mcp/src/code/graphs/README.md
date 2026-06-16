# graphs/ — bundled knowledge-graph data (deploy artifact)

ONE flat bundle codegraph.ts loads at runtime (`/app/code/graphs` in the image).
Canonical sources (do NOT edit here — copies):
  • build-kg-graph_delta.json      ← 2_configs/dist (engine: deriveKgDelta)        [① infra, deterministic]
  • code-signatures-<repo>.json    ← 2_configs/dist (engine: derive-code-signatures) [② code, deterministic]
  • graph-semantic-<repo>.json     ← ca-dat_kg-graph/src (Opus/Sonnet authored)      [③ semantic]
Refreshed on cgc build. codegraph reads CODEGRAPH_GRAPHS_DIR ?? this dir ?? $GIT_ROOT/cloud fallback.
