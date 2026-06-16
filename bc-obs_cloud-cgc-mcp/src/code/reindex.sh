#!/bin/sh
# ── cloud-cgc-mcp · one-shot octocode GraphRAG reindexer ──────────────────────
# Runs in a throwaway container (compose profile "reindex") with the octocode_db
# + octocode_repos volumes mounted RW and the claude-openai-bridge env set. Points
# octocode's LLM (incl. the GraphRAG description/relationship models) at the WG-only
# bridge, then (optionally pulls and) indexes each repo in $OCTOCODE_REPOS.
#
# Declarative: every input is an env var supplied by compose.nix from build.json.
# Re-runnable + idempotent. NOT started by normal `compose up` (profile-gated).
set -eu

export HOME="${OCTOCODE_HOME:-/home/appuser}"
CFG="$HOME/.local/share/octocode/config.toml"
MODEL="${OCTOCODE_LLM_MODEL:-openai:gpt-4o-mini}"
REPOS="${OCTOCODE_REPOS:-cloud unix front tools cloud-data front-data}"
REPOS_ROOT="${OCTOCODE_REPOS_ROOT:-/repos}"
PULL="${OCTOCODE_PULL:-0}"

echo "[reindex] bridge=${OPENAI_BASE_URL:-UNSET} model=$MODEL pull=$PULL repos=[$REPOS]"

# 1. Point octocode's LLM at the bridge. `octocode config --model` sets [llm].model
#    + enables GraphRAG; force the GraphRAG sub-models too (awk, never sed — the
#    model string is plain but the repo rule stands).
octocode config --model "$MODEL" --graphrag-enabled true
if [ -f "$CFG" ]; then
  awk -v m="$MODEL" '
    /^[[:space:]]*description_model[[:space:]]*=/  { print "description_model = \"" m "\""; next }
    /^[[:space:]]*relationship_model[[:space:]]*=/ { print "relationship_model = \"" m "\""; next }
    { print }
  ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
fi
echo "[reindex] effective octocode LLM config:"
octocode config --show 2>&1 | grep -iE "model|graphrag" || true

# 2. (optionally pull) + index each repo. octocode index uses the CWD.
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true
for repo in $REPOS; do
  d="$REPOS_ROOT/$repo"
  [ -d "$d" ] || { echo "[reindex] MISSING $d — skip"; continue; }
  if [ "$PULL" = "1" ] && [ -d "$d/.git" ] && command -v git >/dev/null 2>&1; then
    echo "[reindex] pull $repo"
    git -C "$d" pull --ff-only 2>&1 | tail -1 || echo "[reindex] pull $repo failed (continuing)"
  fi
  nfiles=$(find "$d" -type f 2>/dev/null | wc -l)
  echo "[reindex] === indexing $repo ($nfiles files) ==="
  t0=$(date +%s 2>/dev/null || echo 0)
  ( cd "$d" && octocode index ) 2>&1 | tail -8 || echo "[reindex] index $repo FAILED"
  t1=$(date +%s 2>/dev/null || echo 0)
  echo "[reindex] $repo done in $(( t1 - t0 ))s"
done
echo "[reindex] ALL DONE"
