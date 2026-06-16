#!/bin/sh
# ── cloud-cgc-mcp · one-shot octocode GraphRAG reindexer (LLM via claude bridge) ──
# Runs in a throwaway container (compose profile "reindex") with octocode_db +
# octocode_repos mounted RW and the claude-openai-bridge env set. Points octocode's
# GraphRAG LLM at the bridge, sets use_llm=true (the flag that was OFF → 0 LLM calls),
# then indexes each repo in $OCTOCODE_REPOS.
#
# PROVIDER FALLBACK (one-shot insurance): octocode reaches the bridge two ways —
#   openai:<m>  → OPENAI_API_URL  → bridge /v1
#   ollama:<m>  → localhost:11434 → bridge Ollama mimic
# We try $OCTOCODE_LLM_MODELS in order; after each `octocode index` we diff the
# bridge /health call counter and fall back to the next provider if it made 0 calls.
# octocode is incremental, so a fallback re-index reuses cached embeddings (cheap).
set -eu

export HOME="${OCTOCODE_HOME:-/home/appuser}"
CFG="$HOME/.local/share/octocode/config.toml"
MODELS="${OCTOCODE_LLM_MODELS:-openai:gpt-4o-mini ollama:claude-sonnet}"
REPOS="${OCTOCODE_REPOS:-cloud unix front tools cloud-data front-data}"
REPOS_ROOT="${OCTOCODE_REPOS_ROOT:-/repos}"
HEALTH="${BRIDGE_HEALTH_URL:-http://10.0.0.6:3107/health}"
PULL="${OCTOCODE_PULL:-0}"

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

echo "[reindex] bridge=$HEALTH models=[$MODELS] repos=[$REPOS] use_llm=forced-true"
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true

for repo in $REPOS; do
  d="$REPOS_ROOT/$repo"
  [ -d "$d" ] || { echo "[reindex] MISSING $d — skip"; continue; }
  if [ "$PULL" = "1" ] && [ -d "$d/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$d" pull --ff-only 2>&1 | tail -1 || echo "[reindex] pull $repo failed (continuing)"
  fi
  nfiles=$(find "$d" -type f 2>/dev/null | wc -l)
  ok=0
  for model in $MODELS; do
    echo "[reindex] === $repo ($nfiles files) · provider=$model ==="
    set_provider "$model"
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
done
echo "[reindex] ALL DONE — final bridge calls=$(bridge_calls)"
