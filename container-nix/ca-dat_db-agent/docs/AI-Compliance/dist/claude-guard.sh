#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# claude-guard.sh — Profile-aware enforcement engine for Claude Code hooks
#
# Reads declarative rules from claude-guard-rules.json and enforces them
# based on the current profile (model tier + mode + skill).
#
# Called by Claude Code via settings.json PreToolUse hooks.
# Input: JSON on stdin (tool_name, tool_input.command, tool_input.file_path)
# Output: exit 0 = allow, exit 2 = BLOCK (stderr shown to AI)
# ============================================================================

# === Profile detection (env vars set before launching claude) ===
MODE="${CLAUDE_MODE:-normal}"       # normal | debug
MODEL="${CLAUDE_MODEL:-opus}"       # opus | sonnet | haiku
SKILL="${CLAUDE_SKILL:-}"           # senior-cloud | senior-se | junior-ops | etc.

# === Input parsing (JSON on stdin from Claude Code hooks API) ===
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // .tool_input.old_string // empty')

# === Enforcement functions (mode-aware) ===

# Critical block: ALWAYS enforced, any profile, any mode
block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# Warning: shown to AI as stderr
warn() {
  echo "WARNING: $1" >&2
}

# Standard block: downgrades to warn in debug mode
std_block() {
  if [ "$MODE" = "debug" ]; then
    warn "$1"
  else
    block "$1"
  fi
}

# Standard warn: skipped entirely in debug mode, upgraded to block for junior
std_warn() {
  if [ "$MODE" = "debug" ]; then
    return 0
  elif [ "$MODEL" = "haiku" ]; then
    block "Junior model: $1"
  else
    warn "$1"
  fi
}

# Junior gate: blocks if model is haiku (junior-only), regardless of mode
junior_block() {
  if [ "$MODEL" = "haiku" ]; then
    block "Junior model: $1"
  fi
}

# === Load rules ===
RULES_FILE="${BASH_SOURCE[0]%/*}/claude-guard-rules.json"
[ -f "$RULES_FILE" ] || exit 0

# === Match and enforce rules ===
jq -c '.[]' "$RULES_FILE" | while IFS= read -r rule; do
  rule_tool=$(echo "$rule" | jq -r '.tool')

  # Check if current tool matches rule's tool pattern (supports "Edit|Write")
  echo "$TOOL" | grep -qE "^($rule_tool)$" || continue

  field=$(echo "$rule" | jq -r '.field')
  pattern=$(echo "$rule" | jq -r '.pattern')
  level=$(echo "$rule" | jq -r '.level')
  msg=$(echo "$rule" | jq -r '.message')

  # Select the right input field to match against
  case "$field" in
    command)   VALUE="$CMD" ;;
    file_path) VALUE="$FILE" ;;
    content)   VALUE="$CONTENT" ;;
    *)         continue ;;
  esac

  # Skip if field is empty
  [ -z "$VALUE" ] && continue

  # Match pattern against value
  echo "$VALUE" | grep -qE "$pattern" || continue

  # Pattern matched — enforce based on level
  case "$level" in
    critical_block) block "$msg" ;;
    std_block)      std_block "$msg" ;;
    std_warn)       std_warn "$msg" ;;
    junior_block)   junior_block "$msg" ;;
  esac
done

exit 0
