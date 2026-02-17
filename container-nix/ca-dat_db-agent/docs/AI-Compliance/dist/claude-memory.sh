#!/usr/bin/env bash
# ============================================================================
# claude-memory.sh — SessionStart hook that injects pre-action checklist
#
# Runs at the start of every Claude Code session. Outputs the mandatory
# checklist and forbidden patterns as additionalContext — guaranteed to be
# in the prompt regardless of what Claude does to MEMORY.md.
#
# Called by Claude Code via settings.json SessionStart hooks.
# Input: JSON on stdin (session_id, source, model, cwd, permission_mode)
# Output: stdout text is injected as additional context into the session.
# ============================================================================

cat <<'CHECKLIST'
## MANDATORY PRE-ACTION CHECKLIST

Before EVERY modification:
1. **SOURCE CHECK**: Am I editing SOURCE (git `src/`) or DEPLOYED output (VM, dist/, ~/.claude/)?
2. **PIPELINE CHECK**: Am I using `build.sh` or bypassing it?
3. **SECRETS CHECK**: Am I creating secrets via sops pipeline or manually?
4. **SHELL CHECK**: `command -v` not `which`. Nix source not `sed` on VM.

## FORBIDDEN PATTERNS

| NEVER | ALWAYS |
|-------|--------|
| `ssh vm 'echo > .secrets'` | `src/secrets.yaml` + sops + `build.sh ship` |
| `nix-env -i pkg` | Add to flake + rebuild |
| `sed` on VM `/etc/` files | Edit nix source + deploy |
| `docker compose up` on VM | `build.sh compose` |
| `which cmd` | `command -v cmd` |
| Edit `dist/` files | Edit `src/` + `build.sh build` |
| Edit `~/.claude/CLAUDE.md` | Edit source in `~/git/unix/` flakes |
CHECKLIST
