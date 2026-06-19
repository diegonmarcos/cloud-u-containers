#!/bin/sh
# ── kg-mcp · one-shot octocode GraphRAG reindexer (LLM via claude-api-superset) ──
# Runs in a throwaway container (compose profile "reindex") with octocode_db +
# octocode_repos mounted RW and the superset env set. Points octocode's
# GraphRAG LLM at the superset (kg-bridge successor), sets use_llm=true (the flag
# that was OFF → 0 LLM calls), then indexes each repo in $OCTOCODE_REPOS.
#
# PROVIDER FALLBACK (one-shot insurance): octocode reaches the superset two ways —
#   openai:<m>  → OPENAI_API_URL  → superset /v1 (3117)
#   ollama:<m>  → OLLAMA_API_URL  → superset Ollama mimic (10.0.0.6:11436)
# We try $OCTOCODE_LLM_MODELS in order; after each `octocode index` we diff the
# bridge /health call counter and fall back to the next provider if it made 0 calls.
# octocode is incremental, so a fallback re-index reuses cached embeddings (cheap).
set -eu

export HOME="${OCTOCODE_HOME:-/home/appuser}"
CFG="$HOME/.local/share/octocode/config.toml"
MODELS="${OCTOCODE_LLM_MODELS:-openai:gpt-4o-mini ollama:claude-sonnet}"
REPOS="${OCTOCODE_REPOS:-cloud unix front tools cloud-data front-data}"
REPOS_ROOT="${OCTOCODE_REPOS_ROOT:-/repos}"
HEALTH="${BRIDGE_HEALTH_URL:-http://10.0.0.6:3117/health}"
PULL="${OCTOCODE_PULL:-0}"
# FORCE a fresh index: octocode skips when the git HEAD is unchanged ("No commit
# changes since last index"), but --no-git ALSO skips the GraphRAG AI phase (the
# description/relationship LLM calls). So instead we `octocode clear` the project
# then index WITH git — a fresh full build that runs the AI phase → LLM calls.
# OCTOCODE_CLEAR=1 → force/reindex; =0 → incremental (only changed files).
CLEAR="${OCTOCODE_CLEAR:-1}"
KG_GRAPHS_DIR="${KG_GRAPHS_DIR:-/app/graphs}"; export KG_GRAPHS_DIR

bridge_calls() { curl -s -m 5 "$HEALTH" 2>/dev/null | grep -oE '"calls":[0-9]+' | grep -oE '[0-9]+' | head -1 || echo 0; }

# Force octocode's LLM config: [llm].model + graphrag description/relationship models
# all = $1, and use_llm = true. awk (never sed) — model strings are plain.
set_provider() {
  octocode config --model "$1" --graphrag-enabled true >/dev/null 2>&1 || true
  [ -f "$CFG" ] || return 0
  awk -v m="$1" '
    /^[[:space:]]*use_llm[[:space:]]*=/            { print "use_llm = true"; next }
    /^[[:space:]]*description_model[[:space:]]*=/  { print "description_model = \"" m "\""; next }
    /^[[:space:]]*relationship_model[[:space:]]*=/ { print "relationship_model = \"" m "\""; next }
    { print }
  ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  grep -q "use_llm = true" "$CFG" 2>/dev/null || printf '\n[graphrag]\nuse_llm = true\n' >> "$CFG"
}

# Exclude redundant submodule paths from octocode's walk. Each submodule is its
# OWN repo (indexed separately), so descending into them is duplicate work — and
# on large trees (e.g. unix's I_cloud-data / II_tools / III_front-data) octocode's
# indexer DEADLOCKS recursing the nested submodules (hrtime-parked, 0 progress).
# octocode honors .gitignore (the `ignore` crate also honors .ignore); the path
# list is data-driven from the repo's own .gitmodules — never hardcoded. Writes
# are idempotent into the ephemeral octocode_repos working copy.
exclude_submodules() {
  _d="$1"; _gm="$_d/.gitmodules"
  [ -f "$_gm" ] || return 0
  awk -F'=' '/^[[:space:]]*path[[:space:]]*=/ { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2 }' "$_gm" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    for _f in "$_d/.gitignore" "$_d/.ignore"; do
      grep -qxF "/$_p/" "$_f" 2>/dev/null || printf '/%s/\n' "$_p" >> "$_f"
    done
    echo "[reindex] $_d · exclude submodule: $_p"
  done
}

echo "[reindex] bridge=$HEALTH models=[$MODELS] repos=[$REPOS] use_llm=forced-true"
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true

for repo in $REPOS; do
  d="$REPOS_ROOT/$repo"
  [ -d "$d" ] || { echo "[reindex] MISSING $d — skip"; continue; }
  exclude_submodules "$d"
  if [ "$PULL" = "1" ] && [ -d "$d/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$d" pull --ff-only 2>&1 | tail -1 || echo "[reindex] pull $repo failed (continuing)"
  fi
  nfiles=$(find "$d" -type f 2>/dev/null | wc -l)
  ok=0
  for model in $MODELS; do
    echo "[reindex] === $repo ($nfiles files) · provider=$model ==="
    set_provider "$model"
    [ "$CLEAR" = "1" ] && { echo "[reindex] $repo · clearing index (force fresh)"; ( cd "$d" && octocode clear --mode all ) >/dev/null 2>&1 || true; }
    before=$(bridge_calls)
    t0=$(date +%s 2>/dev/null || echo 0)
    ( cd "$d" && octocode index ) 2>&1 | tail -6 || echo "[reindex] index $repo ($model) FAILED"
    t1=$(date +%s 2>/dev/null || echo 0)
    after=$(bridge_calls)
    delta=$(( after - before ))
    echo "[reindex] $repo · $model → bridge_calls +$delta in $(( t1 - t0 ))s"
    if [ "$delta" -gt 0 ]; then ok=1; echo "[reindex] $repo ✓ LLM via bridge ($model)"; break; fi
    echo "[reindex] $repo ✗ 0 bridge calls with $model — falling back"
  done
  [ "$ok" = 0 ] && echo "[reindex] $repo ⚠ NO provider reached the bridge"
  # ④ Full file-level mirror of octocode's code graph → kg-store (SurrealDB).
  # Reads octocode's Lance tables for this repo and ingests every file node +
  # relationship. Env-gated (kg-ingest no-ops if KG_STORE_PASS unset); cheap export.
  if [ "$ok" = 1 ] && command -v python3 >/dev/null 2>&1; then
    if python3 /app/octocode-export.py "$repo" 2>&1; then
      KG_DELTA="$KG_GRAPHS_DIR/octocode-$repo.json" node /app/kg-ingest.mjs \
        || echo "[reindex] $repo · code-graph ingest failed (continuing)"
    else
      echo "[reindex] $repo · octocode-export failed (continuing)"
    fi
  fi
done
echo "[reindex] octocode code-graph DONE — final bridge calls=$(bridge_calls)"

# ── Also (re)deploy the INFRA knowledge-graph into kg-store (SurrealDB) ────────
# Unified job: after octocode builds the code graph, ingest the infra graph delta
# into the SurrealDB. Env-gated/data-driven — no-ops cleanly if kg-store is not
# configured (KG_STORE_URL / KG_STORE_PASS).
if command -v node >/dev/null 2>&1; then
  node /app/kg-ingest.mjs || echo "[reindex] kg-store ingest failed (continuing)"
else
  echo "[reindex] node not found — kg-store ingest skipped"
fi
echo "[reindex] ALL DONE"
