#!/bin/sh
# ── cloud-cgc-pub-mcp · one-shot octocode GraphRAG reindexer (LLM via claude-api-superset) ──
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
MODELS="${OCTOCODE_LLM_MODELS:-ollama:claude-haiku openai:gpt-4o-mini}"
# No hardcoded repo-list fallback. compose.nix injects OCTOCODE_REPOS from
# build.json .runtime.octocode.index_repos; a baked-in default is just another
# copy to go stale (this one still said "cloud unix front tools" long after the
# cloud-* rename). Fail loudly instead of silently indexing the wrong set.
REPOS="${OCTOCODE_REPOS:?OCTOCODE_REPOS unset — compose.nix must inject it from build.json .runtime.octocode.index_repos}"
# DENY CHECK — compose.nix documents a per-run `-e OCTOCODE_REPOS=<repo>` override to
# scope a manual reindex to one repo (see compose.nix), which bypasses derive-repo-map.ts's
# derive-time check entirely (that check only validates the STATIC build.json index_repos).
# This container mounts the shared /repos volume RW and indexes whatever $REPOS names, so a
# denied repo (e.g. cloud-vault, the credential store) reaching here gets embedded in the
# GraphRAG DB. SYNC_EXCLUDE is injected by compose.nix from the SAME build.json
# .runtime.octocode.sync_exclude as the derive-time check — data-driven, never hardcoded.
for _r in $REPOS; do
  for _d in ${SYNC_EXCLUDE:-}; do
    if [ "$_r" = "$_d" ]; then
      echo "[reindex] ::error:: refusing to index '$_r' — denied by .runtime.octocode.sync_exclude" >&2
      exit 1
    fi
  done
done
REPOS_ROOT="${OCTOCODE_REPOS_ROOT:-/repos}"
# Extension -> EXISTING octocode grammar pairs ("kt=java kts=java"), injected by
# compose.nix from build.json .runtime.octocode.file_associations. Empty is a
# valid state (no associations declared) and is handled in set_file_associations.
FILE_ASSOCIATIONS="${OCTOCODE_FILE_ASSOCIATIONS:-}"
HEALTH="${BRIDGE_HEALTH_URL:-http://10.0.0.6:3117/health}"
PULL="${OCTOCODE_PULL:-0}"
# FORCE a fresh index: octocode skips when the git HEAD is unchanged ("No commit
# changes since last index"), but --no-git ALSO skips the GraphRAG AI phase (the
# description/relationship LLM calls). So instead we `octocode clear` the project
# then index WITH git — a fresh full build that runs the AI phase → LLM calls.
# OCTOCODE_CLEAR=1 → force/reindex; =0 → incremental (only changed files).
CLEAR="${OCTOCODE_CLEAR:-1}"
# SKIP_INDEX=1 → cheap export→ingest only (no octocode index / LLM / bridge calls).
# Used by the CI restore path to refresh SurrealDB in lockstep with a LanceDB
# restore without tripping the freeze-guard. Default 0 = unchanged behavior.
SKIP_INDEX="${OCTOCODE_SKIP_INDEX:-0}"
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

# Apply the declared extension -> grammar map into [index.file_associations].
#
# WHY: octocode 0.22.0 admits a file to the index only if detect_language()
# (src/indexer/file_utils.rs:117) or ALLOWED_TEXT_EXTENSIONS knows its extension
# (src/indexer/mod.rs:401/422). 0.22 ships no Kotlin grammar, so without an
# association every .kt/.kts file is dropped at the FILE WALK — before chunking,
# before embedding. cloud-u-android's ~9,900 Kotlin files were therefore absent
# from the code index entirely, and a search for its primary language returned
# other repos' boilerplate instead of nothing, which reads as a bad ranking
# rather than as a missing corpus. [index.file_associations] (src/language.rs:25)
# maps an extension onto an EXISTING grammar and is the only declarable lever
# 0.22 has for this.
#
# WHY HERE AND NOT ONLY IN CI: the CI producer already applies it
# (cloud-cgc-db-update.sh apply_file_associations). THIS path did not — and this
# path is the one the one-shot reindex/index jobs use, and the one
# cloud-cgc-db-restore-all.sh execs INSIDE the MCP container. So an on-box
# reindex rebuilt a Kotlin-blind index on top of a correctly declared build.json,
# silently undoing the declaration on exactly the boxes that serve queries.
#
# Must run AFTER set_provider(): `octocode config` rewrites config.toml, so
# applying this first would be clobbered on every provider iteration.
#
# IDEMPOTENT + NON-CLOBBERING: rewrites only the extensions we declare, inside
# [index.file_associations] alone; every other section, comment and undeclared
# association stays byte-identical. A missing section is appended as a new table.
# Pairs arrive from compose.nix (build.json .runtime.octocode.file_associations) —
# never hardcoded here, so adding a language stays a build.json edit. awk, never sed.
#
# An unknown grammar name makes octocode REFUSE the config outright
# (normalize_file_associations bails), so a typo fails the run loudly instead of
# silently indexing nothing — which is the exact failure mode this fix ends.
set_file_associations() {
  [ -f "$CFG" ] || return 0
  if [ -z "${FILE_ASSOCIATIONS:-}" ]; then
    echo "[reindex] no OCTOCODE_FILE_ASSOCIATIONS injected — [index.file_associations] left untouched"
    return 0
  fi
  awk -v pairs="$FILE_ASSOCIATIONS" '
    function emit(   i) { for (i = 1; i <= count; i++) printf "%s = \"%s\"\n", ext[i], lang[ext[i]] }
    BEGIN {
      n = split(pairs, declared, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (declared[i] == "") continue
        eq = index(declared[i], "=")
        if (eq < 2) continue
        e = substr(declared[i], 1, eq - 1)
        sub(/^\./, "", e)
        if (!(e in lang)) ext[++count] = e
        lang[e] = substr(declared[i], eq + 1)
      }
    }
    /^\[/ {
      if (in_fa) { emit(); in_fa = 0 }
      if ($0 ~ /^\[index\.file_associations\][ \t]*$/) { in_fa = 1; seen = 1 }
      print; next
    }
    in_fa && /^[ \t]*"?\.?[A-Za-z0-9_+-]+"?[ \t]*=/ {
      key = $0
      sub(/[ \t]*=.*$/, "", key)
      gsub(/[ \t"]/, "", key)
      sub(/^\./, "", key)
      if (key in lang) next
      print; next
    }
    { print }
    END {
      if (in_fa) emit()
      else if (!seen) { printf "\n[index.file_associations]\n"; emit() }
    }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  echo "[reindex] config.toml [index.file_associations] applied: $FILE_ASSOCIATIONS"
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

if [ "$SKIP_INDEX" = "1" ]; then
  echo "[reindex] SKIP_INDEX=1 — cheap export→ingest only (no octocode index / LLM / bridge) repos=[$REPOS]"
else
  echo "[reindex] bridge=$HEALTH models=[$MODELS] repos=[$REPOS] use_llm=forced-true"
fi
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true

for repo in $REPOS; do
  d="$REPOS_ROOT/$repo"
  [ -d "$d" ] || { echo "[reindex] MISSING $d — skip"; continue; }
  if [ "$SKIP_INDEX" = "1" ]; then
    # ④ Cheap mirror only: export octocode's existing Lance tables for this
    # repo → ingest into kg-store (SurrealDB). No index/LLM/bridge calls.
    if command -v python3 >/dev/null 2>&1; then
      if python3 /app/octocode-export.py "$repo" 2>&1; then
        KG_DELTA="$KG_GRAPHS_DIR/octocode-$repo.json" node /app/kg-ingest.mjs \
          || echo "[reindex] $repo · code-graph ingest failed (continuing)"
      else
        echo "[reindex] $repo · octocode-export failed (continuing)"
      fi
    fi
    continue
  fi
  exclude_submodules "$d"
  if [ "$PULL" = "1" ] && [ -d "$d/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$d" pull --ff-only 2>&1 | tail -1 || echo "[reindex] pull $repo failed (continuing)"
  fi
  nfiles=$(find "$d" -type f 2>/dev/null | wc -l)
  ok=0
  for model in $MODELS; do
    echo "[reindex] === $repo ($nfiles files) · provider=$model ==="
    set_provider "$model"
    # AFTER set_provider — `octocode config` above rewrites config.toml.
    set_file_associations
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
if [ "$SKIP_INDEX" = "1" ]; then
  echo "[reindex] octocode code-graph DONE (SKIP_INDEX export→ingest only)"
else
  echo "[reindex] octocode code-graph DONE — final bridge calls=$(bridge_calls)"
fi

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
