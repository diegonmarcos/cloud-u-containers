#!/usr/bin/env bash
# ============================================================================
# b-context-inject-prompt.sh — TIER B: UserPromptSubmit context injector
#
# Fires on EVERY user prompt. Emits FIRE rules + Stack Philosophy + checklist
# + forbidden patterns to stdout — Claude Code captures as additionalContext.
# Deliberate per-prompt repetition pressure to prevent mid-session drift.
#
# Source: ~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/src/modules/dotfiles/claude/
# Deployed: ~/.claude/hooks/b-context-inject-prompt.sh (via home-manager)
# Wired in: settings.json → hooks.UserPromptSubmit[0].hooks[0].command
# ============================================================================

cat <<'GUARD'
## CORE PRINCIPLES (non-negotiable — reinforced at EVERY tier of hook injection)

1. **FULLY DECLARATIVE** — every change goes through source files in git; never imperative ad-hoc one-liners.
2. **FULLY DATA-DRIVEN** — data lives in `build.json` / `2_configs/*.json`; never hardcoded inline in scripts.
3. **FULLY REPRODUCIBLE** — same input → same output, every time, every machine, every clean build.
4. **IMPERATIVE SOLUTIONS FORBIDDEN** — no `ssh vm 'echo > x'`, no `sed -i` on VMs, no `nix-env -i`, no ad-hoc patches.
5. **FOUND A BUG IN AN ENGINE → FIX IT.** NO HACKS ALLOWED. No workarounds, no temporary bypasses, no "for now" patches.
6. **FOUND A NON-DATA-DRIVEN INLINED HARDCODED SOLUTION → FIX IT.** Move the data to JSON; refactor the script to read it. Never extend a hardcoded list — replace it.
7A. **USE SOPS.** Secrets live in `src/secrets.yaml` (sops+age). Decrypt only into `dist/.secrets` (gitignored). Path: `build.sh secrets`. Never inline credentials in source/scripts/env.
7B. **PREVENT EXPOSURE.** Never `git add` `.env` / `.key` / `.pem` / `.age` / `*secret*` / `dist/.secrets`. `secrets.yaml` may be committed only when it carries the sops marker (`^sops:` block / `ENC[AES256_GCM` values) — content-checked, not filename-trusted. Never `git add -f`. Vault carve-out: raw key material that *is* the credential (age keys, `~/git/vault/A0_keys/...`).
8. **ASK, DON'T ASSUME.** If intent, architecture, or requirements are unclear, ASK before writing a line. No silent guesses about scope, placement, or wiring — clarify first, code second. Silent guesses become silent commits become silent regressions.

## FIRE RULES (non-negotiable)
1. NO INLINE COMMANDS FULL OF ARGS. NO HACKS EVER. Always fix the engine (`build.sh` / `_engine.sh` / flake) — never bypass it with a one-liner.
2. **INTERVAL CONFIDENCE LEVEL**: By default the model MUST answer at 97.5% confidence. ≤ 2.5% may be extrapolation; ≥ 97.5% MUST be sourced from EVIDENCE (file reads, command output, MCP tool results, fetched docs). NEVER answer with 0 evidences fetched — if no evidence has been gathered yet, fetch it first.
3. NO IMPERATIVE SOLUTION if it is not already DECLARED. An "easy fix" is not a fix — it is a new potential BUG. Declarative always.
4. DATA-DRIVEN ONLY. Never hardcode data in scripts. Use `build.json` or auxiliary `.json` files (in `2_configs/`) as the source of truth.
5. A TASK IS NOT DONE UNTIL IT HAS A TESTER. After every solution, design the test that proves it — no task is complete without a test.
6. **NEVER GUESS THE CODE / INFRA ARCHITECTURE — USE cloud-cgc-mcp.** The `cloud-cgc-mcp` (code-graph-context) server is ONLINE. Before reasoning about how the code/build/runner/topology works, query it: `octocode_search` / `octocode_graphrag` (semantic code + call-graph), `knowledge_*` / `c3_*` (services, runners, configs, topology). Reading 5 files and guessing the 6th is the bug — be SURE via cloud-cgc-mcp, THEN act. Guessing architecture is forbidden when the graph can tell you.

## Stack Philosophy
0. IMPERATIVE SOLUTIONS ARE FORBIDDEN
1. FULLY DECLARATIVE ENVIRONMENT
2. BUILD AND CI/CD ONLY DONE BY UNIVERSAL ENGINES
3. MCP TOOLS USE IS MANDATORY
4. WHEN DETECTED A BUG IN AN ENGINE THE ISSUE MUST BE FIXED IMMEDIATELY NOT BE BYPASSED BY TEMPORARY WORKAROUNDS EVER!

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

## DEAD SHELL RECOVERY

If Bash fails on everything (even `echo test`), the CWD was deleted by git mv/rm.
**Fix**: Use `Write` tool to create a dummy file at the dead path → restores CWD → Bash works again.
Then clean up with `git checkout HEAD -- path/` or continue with absolute paths.
GUARD
