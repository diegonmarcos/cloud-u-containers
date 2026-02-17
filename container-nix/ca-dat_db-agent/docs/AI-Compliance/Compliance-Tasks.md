# Compliance Tasks

Extracted from [Compliance-Plan.md](Compliance-Plan.md).

---

## Layer 0: Documentation

- [x] Save compliance plan to `docs/AI-Compliance/`
- [x] Create task tracker (this file)
- [x] Create README index at `docs/`

## Layer 1: Hooks — Hard Enforcement (Tier 1)

- [ ] Create `claude-guard.sh` source (Termux flake: `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/claude-guard.sh`)
- [ ] Implement all 30 existing rules from claude-guard.md spec
- [ ] Add 3 new gap rules (#30 SSH+secrets BLOCK, #31 SSH+sed WARN, #32 scp+deploy WARN)
- [ ] Create `settings.json` source for Termux with `hooks.PreToolUse` config
- [ ] Add hooks to Desktop `settings.json` source
- [ ] Add `home.file` entries to Termux nix flake (guard.sh + settings.json)
- [ ] Sync guard script to Desktop flake source
- [ ] Rebuild Termux flake (`build.sh switch`)
- [ ] Test: `which` → BLOCK (exit 2)
- [ ] Test: Edit `~/.claude/CLAUDE.md` → BLOCK (exit 2)
- [ ] Test: `nix-env -i` → WARN (stderr)
- [ ] Test: `git status` → ALLOW (exit 0)

## Layer 1.5: Profile System

- [ ] Implement profile detection in guard script (`$CLAUDE_MODE`, `$CLAUDE_MODEL`, `$CLAUDE_SKILL`)
- [ ] Implement 4 enforcement functions: `block()`, `std_block()`, `std_warn()`, `junior_block()`
- [ ] Categorize all 33 rules into: critical BLOCK, standard BLOCK, WARN, skill-gated
- [ ] Test debug mode: `CLAUDE_MODE=debug` downgrades standard BLOCKs to WARNs, skips WARNs
- [ ] Test junior gate: `CLAUDE_MODEL=haiku` blocks `build.sh ship` and VM lifecycle
- [ ] Document model-skill mapping: Haiku=Junior, Sonnet=mid-Senior, Opus=all

## Layer 2: MEMORY.md — Pre-Action Checklist (Tier 2)

- [ ] Add `## MANDATORY PRE-ACTION CHECKLIST` at top (4 checks)
- [ ] Add `## FORBIDDEN PATTERNS` table (7 NEVER→ALWAYS rows)
- [ ] Verify MEMORY.md under 200 lines

## Layer 3: CLAUDE.md — Index (Tier 3)

- [ ] Replace FORBIDDEN ACTIONS approach with short Enforcement Layers index table
- [ ] Sync Desktop CLAUDE.md source
- [ ] Verify deployed `~/.claude/CLAUDE.md` has index after flake rebuild

## Layer 4: Fix KG+Rig rsync Bug

- [ ] Remove `--exclude='.secrets'` from `ca-dat_kg-graph/build.sh`
- [ ] Remove `--exclude='.secrets'` from `bc-obs_rig/build.sh`
- [ ] Run `build.sh ship` for kg-graph
- [ ] Run `build.sh ship` for rig
- [ ] Verify `.secrets` on oci-apps VM for both services
- [ ] Verify containers running with env vars
- [ ] Commit build.sh fixes to cloud repo

## Layer 5: Verify docker.service on oci-apps

- [ ] Check docker.service matches nix template
- [ ] Check for sed artifacts (.bak, .orig)
- [ ] Redeploy home-manager if needed
- [ ] Verify docker running with nix-managed binary

## Layer 6: Update Docs + Final Verification

- [ ] Update claude-guard.md: add 3 new rules (#30-32)
- [ ] Update claude-guard.md: fix "exit 1" → "exit 2" = BLOCK
- [ ] Update claude-guard.md: fix "CLI arguments" → "JSON on stdin"
- [ ] `claude-guard.sh` deployed and executable
- [ ] `settings.json` has `hooks.PreToolUse`
- [ ] MEMORY.md has PRE-ACTION checklist
- [ ] CLAUDE.md has Enforcement Layers index
- [ ] KG+Rig `.secrets` on oci-apps
- [ ] No `--exclude='.secrets'` in build.sh
- [ ] docker.service nix-managed
- [ ] Commit docs updates to cloud repo
