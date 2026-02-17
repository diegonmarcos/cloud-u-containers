# Plan: AI Compliance Enforcement

## Context

During KG-Graph + Rig deployment, Claude (Opus) violated rules 4 times — editing deployed output instead of source, bypassing `build.sh`. The guard script (`claude-guard.sh`) was documented with 30 rules but **never implemented**. No enforcement existed.

## Enforcement Hierarchy

```
Tier 1: HOOKS (settings.json → claude-guard.sh)
        └── ONLY layer that can BLOCK (exit 2) or WARN (stderr)
        └── Fires on every tool call — AI cannot bypass
        └── 33 rules: 17 BLOCK + 16 WARN
        └── PROFILE-AWARE: model tier, mode, skill

Tier 2: MEMORY.md (pre-loaded, 200 lines max)
        └── Mandatory pre-action checklist (4 checks)
        └── Forbidden patterns table (7 NEVER→ALWAYS)
        └── AI reads before acting — concise = effective

Tier 3: CLAUDE.md (pre-loaded, full file)
        └── System map: stack, VMs, services, paths, APIs, code standards
        └── Indexes enforcement files — does NOT duplicate rules
        └── NOT for strict rules (500+ lines = context dilution)
```

## Profile System

A **profile** = model tier + skill + mode. Determines what the AI can do.

```
MODEL TIER (capability gate):
├── Haiku  → Junior skills only (Junior SE, Junior Ops)
│            Extra BLOCKs: no build.sh ship, no VM lifecycle, no architecture changes
├── Sonnet → Junior + mid-Senior (Front-End, Designer)
│            Standard enforcement
└── Opus   → All skills (Cloud Architect, Software Engineer, Architecture)
             Standard enforcement

MODE (enforcement level):
├── Normal → Full enforcement (17 BLOCK + 16 WARN)
└── Debug  → Relaxed (critical BLOCKs stay, others → WARN, WARNs → allow)

SKILL (role-based access):
├── Senior Cloud Architect → full infra: build.sh ship, VM lifecycle, secrets
├── Senior Software Engineer → code: Rust API, MCP server, Nix flakes
├── Senior Front-End → front repo: build, dev server, SCSS/TS
├── Junior Ops → read-only infra: docker logs, health checks, restarts
└── Junior SE → scoped code: bug fixes, follows existing patterns
```

**Profile detection** in `claude-guard.sh`:
- `$CLAUDE_MODE` env var → `normal` (default) or `debug`
- Model tier → from JSON stdin if available, else env `$CLAUDE_MODEL`
- Skill → from `$CLAUDE_SKILL` env var (set by skill prompt activation)

**Rule categories** by profile:
| Rule type | Normal | Debug | Junior model |
|-----------|--------|-------|-------------|
| Critical BLOCK (manual .secrets, edit deployed, which) | BLOCK | BLOCK | BLOCK |
| Standard BLOCK (nix build, nixos-rebuild) | BLOCK | WARN | BLOCK |
| WARN (nix-env, npm install, ssh docker) | WARN | allow | BLOCK |
| Skill-gated (build.sh ship, VM lifecycle) | per skill | per skill | BLOCK |

### The 4 violations and which tier catches them

| Mistake | Hooks (Tier 1) | MEMORY.md (Tier 2) |
|---|---|---|
| `which` | Rule #29 BLOCK — stopped | Forbidden patterns table |
| `nix-env -i sops` | Rule #24 WARN — warned | Forbidden patterns table |
| `sed` on VM | **NEW** Rule #31 WARN | Pre-action checklist Q1 |
| Manual `.secrets` on VM | **NEW** Rule #30 BLOCK — stopped | Pre-action checklist Q3 |

---

## Layer 1: Hooks — Hard Enforcement (Tier 1)

### 1.1 Create `claude-guard.sh`

**Source** (Termux): `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/claude-guard.sh`
**Source** (Desktop): `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/claude-guard.sh`
**Deployed to**: `~/.claude/hooks/claude-guard.sh` (via home-manager, executable)

**Claude Code Hooks API**:
- `PreToolUse` event fires before tool execution
- Hook receives **JSON on stdin**: `tool_name`, `tool_input.command`, `tool_input.file_path`, etc.
- **Exit 0** = allow, **Exit 2** = BLOCK (stderr shown to AI as feedback)
- Requires `jq` to parse stdin

**Architecture**: Declarative JSON rules + generic bash engine.

```
~/.claude/
├── hooks/
│   ├── claude-guard.sh          ← Engine (generic, reads rules.json)
│   └── claude-guard-rules.json  ← Rules (33 rules, edit without touching bash)
└── settings.json                ← Wiring (calls claude-guard.sh on tool use)
```

**`claude-guard-rules.json`** (all 33 rules):
```json
[
  {"id":1,  "tool":"Bash",      "field":"command",   "pattern":"\\bwhich\\b",                                    "level":"critical_block", "message":"Use 'command -v' (doesn't exist on Termux/Nix)"},
  {"id":2,  "tool":"Bash",      "field":"command",   "pattern":"ssh.*(echo|cat).*>.*\\.secrets",                 "level":"critical_block", "message":"Create src/secrets.yaml + sops, then build.sh ship"},
  {"id":3,  "tool":"Bash",      "field":"command",   "pattern":"\\.claude/CLAUDE\\.md|\\.mcp\\.json",           "level":"critical_block", "message":"Edit source in ~/git/unix/ flakes, not deployed output"},
  {"id":4,  "tool":"Bash",      "field":"command",   "pattern":"^nix (build|run|develop)\\b",                   "level":"std_block",      "message":"Use ./build.sh build"},
  {"id":5,  "tool":"Bash",      "field":"command",   "pattern":"\\bnixos-rebuild\\b",                           "level":"std_block",      "message":"Use build.sh switch"},
  {"id":6,  "tool":"Bash",      "field":"command",   "pattern":"\\bhome-manager switch\\b",                     "level":"std_block",      "message":"Use build.sh switch"},
  {"id":7,  "tool":"Bash",      "field":"command",   "pattern":"\\bnix-on-droid switch\\b",                     "level":"std_block",      "message":"Use build.sh switch"},
  {"id":8,  "tool":"Bash",      "field":"command",   "pattern":"\\bnix-env -i\\b|nix profile install",          "level":"std_warn",       "message":"Add to nix flake instead"},
  {"id":9,  "tool":"Bash",      "field":"command",   "pattern":"ssh.*sed.*-i",                                  "level":"std_warn",       "message":"Edit Nix source instead of sed on VM"},
  {"id":10, "tool":"Bash",      "field":"command",   "pattern":"ssh.*docker compose",                           "level":"std_warn",       "message":"Use build.sh ship"},
  {"id":11, "tool":"Bash",      "field":"command",   "pattern":"\\bnpm run (build|dev)\\b",                     "level":"std_warn",       "message":"Use ./build.sh build or ./build.sh dev"},
  {"id":12, "tool":"Bash",      "field":"command",   "pattern":"\\bpip3? install\\b",                           "level":"std_warn",       "message":"Add to nix flake instead"},
  {"id":13, "tool":"Bash",      "field":"command",   "pattern":"build\\.sh ship",                               "level":"junior_block",   "message":"build.sh ship requires Senior skill"},
  {"id":14, "tool":"Bash",      "field":"command",   "pattern":"build\\.sh compose",                            "level":"junior_block",   "message":"build.sh compose requires Senior skill"},
  {"id":15, "tool":"Bash",      "field":"command",   "pattern":"vm_(start|stop|reset)",                         "level":"junior_block",   "message":"VM lifecycle requires Senior skill"},
  {"id":16, "tool":"Bash",      "field":"command",   "pattern":"\\bsops\\b",                                    "level":"junior_block",   "message":"Secrets management requires Senior skill"},
  {"id":17, "tool":"Bash",      "field":"command",   "pattern":"\\bssh\\b",                                     "level":"junior_block",   "message":"SSH access requires Senior skill"},
  {"id":18, "tool":"Edit|Write","field":"file_path", "pattern":"\\.claude/CLAUDE\\.md$",                        "level":"critical_block", "message":"Edit source in ~/git/unix/ flakes"},
  {"id":19, "tool":"Edit|Write","field":"file_path", "pattern":"\\.mcp\\.json$",                                "level":"critical_block", "message":"Edit source in ~/git/unix/ flakes"},
  {"id":20, "tool":"Edit|Write","field":"file_path", "pattern":"/dist/",                                        "level":"critical_block", "message":"Edit src/, then build.sh build"},
  {"id":21, "tool":"Edit|Write","field":"file_path", "pattern":"^/nix/store/",                                  "level":"critical_block", "message":"Nix store is immutable"},
  {"id":22, "tool":"Edit|Write","field":"file_path", "pattern":"\\.claude/settings\\.json$",                    "level":"std_block",      "message":"Edit source in ~/git/unix/ flakes"},
  {"id":23, "tool":"Edit|Write","field":"file_path", "pattern":"front/package\\.json$",                         "level":"std_block",      "message":"Auto-generated by deploy.sh — edit project package.json"},
  {"id":24, "tool":"Edit|Write","field":"file_path", "pattern":"flake\\.nix$",                                  "level":"junior_block",   "message":"Flake changes require Senior skill"},
  {"id":25, "tool":"Edit|Write","field":"file_path", "pattern":"build\\.sh$",                                   "level":"junior_block",   "message":"Build system changes require Senior skill"}
]
```
*(Remaining rules #26-33 from claude-guard.md — code quality patterns for inline CSS, Svelte 4, etc.)*

**`claude-guard.sh`** (generic engine):
```bash
#!/usr/bin/env bash
set -euo pipefail

# === Profile detection ===
MODE="${CLAUDE_MODE:-normal}"
MODEL="${CLAUDE_MODEL:-opus}"
SKILL="${CLAUDE_SKILL:-}"

# === Input parsing ===
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# === Enforcement functions ===
block()        { echo "BLOCKED: $1" >&2; exit 2; }
warn()         { echo "WARNING: $1" >&2; }
std_block()    { if [ "$MODE" = "debug" ]; then warn "$1"; else block "$1"; fi; }
std_warn()     { if [ "$MODE" != "debug" ]; then warn "$1"; fi; }
junior_block() { if [ "$MODEL" = "haiku" ]; then block "Junior model: $1"; fi; }

# === Load rules ===
RULES_FILE="${BASH_SOURCE[0]%/*}/claude-guard-rules.json"
[ -f "$RULES_FILE" ] || exit 0

# === Match rules ===
jq -c '.[]' "$RULES_FILE" | while IFS= read -r rule; do
  rule_tool=$(echo "$rule" | jq -r '.tool')
  # Check if current tool matches rule's tool pattern
  echo "$TOOL" | grep -qE "^($rule_tool)$" || continue

  field=$(echo "$rule" | jq -r '.field')
  pattern=$(echo "$rule" | jq -r '.pattern')
  level=$(echo "$rule" | jq -r '.level')
  msg=$(echo "$rule" | jq -r '.message')

  # Select the right input field
  case "$field" in
    command)   VALUE="$CMD" ;;
    file_path) VALUE="$FILE" ;;
    *)         continue ;;
  esac

  # Match pattern
  echo "$VALUE" | grep -qE "$pattern" || continue

  # Enforce
  case "$level" in
    critical_block) block "$msg" ;;
    std_block)      std_block "$msg" ;;
    std_warn)       std_warn "$msg" ;;
    junior_block)   junior_block "$msg" ;;
  esac
done

exit 0
```

### 1.2 Configure `settings.json` Hooks

**Source** (Termux): `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/settings.json` — **CREATE**
**Source** (Desktop): `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/settings.json` — **EDIT**

Merge hooks into existing settings:
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "\"$HOME\"/.claude/hooks/claude-guard.sh", "timeout": 5 }]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "\"$HOME\"/.claude/hooks/claude-guard.sh", "timeout": 5 }]
      }
    ]
  }
}
```

### 1.3 Add home-manager entries (Termux flake)

```nix
home.file.".claude/hooks/claude-guard.sh" = {
  source = ./dotfiles/claude/claude-guard.sh;
  executable = true;
};
home.file.".claude/hooks/claude-guard-rules.json".source = ./dotfiles/claude/claude-guard-rules.json;
home.file.".claude/settings.json".source = ./dotfiles/claude/settings.json;
```

### 1.4 Test hooks

```bash
# Manual test:
echo '{"tool_name":"Bash","tool_input":{"command":"which python"}}' | ~/.claude/hooks/claude-guard.sh
# Expected: "BLOCKED: Use 'command -v'..." exit 2

echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/user/.claude/CLAUDE.md"}}' | ~/.claude/hooks/claude-guard.sh
# Expected: "BLOCKED: Edit source at..." exit 2

echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | ~/.claude/hooks/claude-guard.sh
# Expected: exit 0 (clean allow)
```

---

## Layer 2: MEMORY.md — Pre-Action Checklist (Tier 2)

**File**: `~/.claude/projects/.../memory/MEMORY.md`

### 2.1 Add at TOP of MEMORY.md

```markdown
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
```

---

## Layer 3: CLAUDE.md — System Map + Index (Tier 3)

**Files** (both byte-identical):
- `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/CLAUDE.md`
- `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/CLAUDE.md`

### 3.1 Replace the FORBIDDEN ACTIONS approach

Instead of adding a duplicate rules table to CLAUDE.md (which gets diluted in 500+ lines), add a short **index section** in Section E after the boxed warning:

```markdown
### Enforcement Layers

Rules are enforced by hooks, not by this file. This file provides system context.

| Layer | File | Role |
|-------|------|------|
| **BLOCK/WARN** | `~/.claude/hooks/claude-guard.sh` | 33 rules, hard enforcement (exit 2 = block) |
| **Checklist** | `MEMORY.md` (auto-loaded) | Pre-action checklist, forbidden patterns |
| **Context** | This file (CLAUDE.md) | System map, architecture, code standards |

See `~/git/cloud/.../ca-dat_db-agent/docs/AI-Compliance/` for full spec.
```

### 3.2 Sync Desktop + Rebuild Termux flake

---

## Layer 4: Fix KG+Rig rsync Bug

**BUG**: Both `build.sh` have `rsync --exclude='.secrets'` — secrets never deployed to VM.

**4.1** Remove `--exclude='.secrets'` from:
- `~/git/cloud/.../ca-dat_kg-graph/build.sh`
- `~/git/cloud/.../bc-obs_rig/build.sh`

**4.2** Run `build.sh ship` for both services
**4.3** Verify `.secrets` on oci-apps VM
**4.4** Commit to cloud repo

---

## Layer 5: Verify docker.service on oci-apps

**5.1** Check docker.service matches nix template
**5.2** Check for sed artifacts
**5.3** Redeploy home-manager if needed
**5.4** Verify docker running with nix-managed binary

---

## Layer 6: Update Docs + Final Verification

### 6.1 Update claude-guard.md

- Add 3 new rules (#30-32)
- Fix exit code: "exit 1" → **exit 2** = BLOCK
- Fix input: "CLI arguments" → **JSON on stdin**

### 6.2 Update Compliance-Plan.md + Compliance-Tasks.md

Mirror this plan to the repo docs.

### 6.3 Final Verification

| # | Check | Expected |
|---|-------|----------|
| 1 | `claude-guard.sh` at `~/.claude/hooks/` | executable |
| 2 | `settings.json` has `hooks.PreToolUse` | configured |
| 3 | `which node` triggers BLOCK | exit 2 |
| 4 | Edit `~/.claude/CLAUDE.md` triggers BLOCK | exit 2 |
| 5 | `nix-env -i x` triggers WARN | stderr warning |
| 6 | MEMORY.md has PRE-ACTION checklist | match |
| 7 | CLAUDE.md has Enforcement Layers index | match |
| 8 | KG+Rig `.secrets` on oci-apps | present |
| 9 | No `--exclude='.secrets'` in build.sh | 0 matches |
| 10 | docker.service nix-managed | match |
| 11 | claude-guard.md exit codes fixed | exit 2 |

---

## Execution Order

```
Layer 1.1 (guard script)    ─┐
Layer 2.1 (MEMORY.md)       ─┤── Parallel (write files)
Layer 3.1 (CLAUDE.md index)  ─┤
Layer 5.1-5.2 (check docker) ─┘
         │
         ▼
Layer 1.2-1.3 (settings.json + nix config)
Rebuild Termux flake (deploys guard + settings + CLAUDE.md)
Commit unix repo
         │
         ▼
Layer 1.4 (test hooks)
Layer 4.1 (fix rsync bug)
         │
         ▼
Layer 4.2 (build.sh ship × 2)
Layer 4.4 (commit cloud)
Layer 5.3-5.4 (fix docker if needed)
Layer 6.1-6.2 (update docs)
         │
         ▼
Layer 6.3 (final verification)
```

---

## Critical Files

| File | Action |
|------|--------|
| `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/claude-guard.sh` | **CREATE**: generic engine |
| `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/claude-guard-rules.json` | **CREATE**: 33 rules (declarative) |
| `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/settings.json` | **CREATE**: hooks config |
| `~/git/unix/bb_flakes_termux/src/modules/.../flake or common.nix` | Edit: home.file entries |
| `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/claude-guard.sh` | **CREATE**: sync engine |
| `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/claude-guard-rules.json` | **CREATE**: sync rules |
| `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/settings.json` | Edit: add hooks |
| `~/.claude/projects/.../memory/MEMORY.md` | Edit: checklist + forbidden table |
| `~/git/unix/.../CLAUDE.md` (both) | Edit: replace rules with index |
| `~/git/cloud/.../ca-dat_kg-graph/build.sh` | Edit: remove --exclude='.secrets' |
| `~/git/cloud/.../bc-obs_rig/build.sh` | Edit: remove --exclude='.secrets' |
| `~/git/cloud/.../docs/AI-Compliance/claude-guard.md` | Edit: fix exit codes + new rules |
| `~/git/cloud/.../docs/AI-Compliance/Compliance-*.md` | Update: mirror plan + tasks |

---

## Current Status

### Done (docs committed + pushed)
- [x] Compliance-Plan.md, Compliance-Tasks.md, README.md
- [x] 4 claude-*.md spec files

### Done (written, NOT yet committed)
- [x] `normal/senior/profile.md`, `normal/mid/profile.md`, `normal/junior/profile.md`
- [x] `debug/senior/profile.md`, `debug/mid/profile.md`, `debug/junior/profile.md`
- [x] `per-project/cloud/rules.md`, `per-project/unix/rules.md`, `per-project/vault/rules.md`, `per-project/front/rules.md`
- [ ] Update `docs/README.md` to include new folder structure

### Not started (implementation)
- [ ] Layer 1: Create `claude-guard.sh` + `settings.json` + home-manager entries
- [ ] Layer 2: Add pre-action checklist to MEMORY.md
- [ ] Layer 3: Add enforcement index to CLAUDE.md
- [ ] Layer 4: Fix rsync `--exclude='.secrets'` bug
- [ ] Layer 5: Verify docker.service on oci-apps
- [ ] Layer 6: Update claude-guard.md spec + final verification

### Immediate next steps
1. Update `docs/README.md` to include profile folders
2. Commit + push all 10 new profile files to cloud repo
3. Begin Layer 1 implementation (claude-guard.sh)

---

## Commits (4 total)

| # | Repo | Message |
|---|------|---------|
| 0 | cloud | `docs(db-agent): add profile system — 6 mode/tier profiles + 4 per-project rules` |
| 1 | unix | `feat(claude): implement claude-guard.sh hooks + enforcement index in CLAUDE.md` |
| 2 | cloud | `fix(kg-graph,rig): remove --exclude='.secrets' from rsync deploy` |
| 3 | cloud | `docs(db-agent): update compliance docs — fix exit codes, add new rules, update plan` |
