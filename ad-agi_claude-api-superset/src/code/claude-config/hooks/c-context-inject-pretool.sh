#!/usr/bin/env bash
# ============================================================================
# c-context-inject-pretool.sh — TIER C: PreToolUse(Bash) context injector
#
# Fires BEFORE every Bash tool call. Emits a compact CORE PRINCIPLES reminder
# via PreToolUse's hookSpecificOutput.additionalContext — so the model sees
# the rules at the exact decision point where they matter most: just before
# running a shell command.
#
# Tier model:
#   a) SessionStart       → a-context-inject-memory.sh         (full rules, once)
#   b) UserPromptSubmit   → b-context-inject-prompt.sh         (full rules, every prompt)
#   c) PreToolUse(Bash)   → c-context-inject-pretool.sh        (compact rules, every Bash call)  ← THIS
#                         + c-pretool-guard-blockers.sh        (deny on hard patterns)
#                         + c-pretool-guard-warning.sh         (warn on advisory patterns)
#
# Why JSON output: PreToolUse stdout in plain-text mode goes only to the
# user-visible transcript. To make additionalContext reach the MODEL, the
# hook must emit a JSON object with hookSpecificOutput.additionalContext
# (per Claude Code hooks spec). Plain stdout text on this event is shown to
# the user but doesn't modify the model's prompt.
#
# Source: ~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/src/modules/dotfiles/claude/
# Deployed: ~/.claude/hooks/c-context-inject-pretool.sh (via home-manager)
# ============================================================================

set -euo pipefail

INPUT=$(cat 2>/dev/null || true)

# Only act on Bash tool calls (matcher in settings.json should already filter,
# but defensive check in case it's invoked broadly).
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Compact CORE PRINCIPLES — same wording as tier A/B but trimmed for per-call
# repetition cost. ~120 tokens per Bash call (vs ~790 for the per-prompt block).
read -r -d '' CONTEXT <<'PRINCIPLES' || true
## CORE PRINCIPLES (per-tool-call reminder)

1. FULLY DECLARATIVE — never imperative one-liners.
2. FULLY DATA-DRIVEN — never hardcode in scripts; data lives in `2_configs/*.json` or `build.json`.
3. FULLY REPRODUCIBLE — same input → same output, every machine.
4. IMPERATIVE SOLUTIONS FORBIDDEN — no `ssh vm 'echo > x'`, no `sed -i` on VMs, no `nix-env -i`.
5. FOUND A BUG IN AN ENGINE → FIX IT. NO HACKS, NO WORKAROUNDS, NO BYPASSES.
6. FOUND HARDCODED INLINED DATA → MOVE IT TO JSON. Never extend a hardcoded list.
7A. SECRETS = SOPS. src/secrets.yaml encrypted; dist/.secrets gitignored. Never inline credentials.
7B. NEVER git add .env/.key/.pem/.age/*secret*/dist/.secrets. secrets.yaml needs sops marker. Vault is the only carve-out.
8. ASK, DON'T ASSUME — clarify unclear intent/architecture/requirements before any tool call. No silent guesses.
9. NEVER GUESS ARCHITECTURE — cloud-cgc-mcp is ONLINE; use octocode_search / octocode_graphrag + knowledge_* / c3_* to read the real code, runners, and topology BEFORE acting. Don't read-5-files-and-guess-the-6th.
PRINCIPLES

# Emit JSON with hookSpecificOutput.additionalContext so the model receives
# this as part of its tool-decision context (not just transcript noise).
jq -nc --arg ctx "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $ctx
    }
}'

exit 0
