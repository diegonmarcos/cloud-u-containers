#!/usr/bin/env bash
# ============================================================================
# a-context-inject-memory.sh — TIER A: SessionStart context injector
#
# Fires once per Claude Code session. Emits the mandatory pre-action checklist
# + forbidden-pattern table to stdout — Claude Code captures it as
# additionalContext, persisting in the conversation prompt for the whole
# session.
#
# Source: ~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/src/modules/dotfiles/claude/
# Deployed: ~/.claude/hooks/a-context-inject-memory.sh (via home-manager)
# Wired in: settings.json → hooks.SessionStart[0].hooks[0].command
#
# Tier model:
#   a) SessionStart       → CLAUDE.md + a-context-inject-memory.sh
#   b) UserPromptSubmit   → b-context-inject-prompt.sh
#   c) PreToolUse(Bash)   → c-pretool-guard-blockers.sh (deny patterns)
#                         + c-pretool-guard-warning.sh (advisory patterns)
# ============================================================================

cat <<'CHECKLIST'
## CORE PRINCIPLES (non-negotiable — reinforced at EVERY tier of hook injection)

1. **FULLY DECLARATIVE** — every change goes through source files in git; never imperative ad-hoc one-liners.
2. **FULLY DATA-DRIVEN** — data lives in `build.json` / `2_configs/*.json`; never hardcoded inline in scripts.
3. **FULLY REPRODUCIBLE** — same input → same output, every time, every machine, every clean build.
4. **IMPERATIVE SOLUTIONS FORBIDDEN** — no `ssh vm 'echo > x'`, no `sed -i` on VMs, no `nix-env -i`, no ad-hoc patches.
5. **FOUND A BUG IN AN ENGINE → FIX IT.** NO HACKS ALLOWED. No workarounds, no temporary bypasses, no "for now" patches. The engine is the contract; bugs in it are root-cause material.
6. **FOUND A NON-DATA-DRIVEN INLINED HARDCODED SOLUTION → FIX IT.** Move the data to JSON, refactor the script to read it. Never extend a hardcoded list — replace it.
7A. **USE SOPS.** Secrets live in `src/secrets.yaml` (sops+age). Decrypt only into `dist/.secrets` (gitignored). Path: `build.sh secrets`. Never inline credentials in source/scripts/env.
7B. **PREVENT EXPOSURE.** Never `git add` `.env` / `.key` / `.pem` / `.age` / `*secret*` / `dist/.secrets`. `secrets.yaml` may be committed only when it carries the sops marker (`^sops:` block / `ENC[AES256_GCM` values) — content-checked, not filename-trusted. Never `git add -f`. Vault carve-out: raw key material that *is* the credential (age keys, `~/git/vault/A0_keys/...`).
8. **ASK, DON'T ASSUME.** If intent, architecture, or requirements are unclear, ASK before writing a line. No silent guesses about scope, placement, or wiring — clarify first, code second. Silent guesses become silent commits become silent regressions.

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
| `cd dir && git mv dir/...` | `git -C /abs/path mv ...` (absolute paths) |
| `git add -f` / `git add --force` | plain `git add` — NEVER bypass gitignore. `-f` force-stages secrets, decrypted keys, sensitive/ — gitignore exists for a reason. |
CHECKLIST
