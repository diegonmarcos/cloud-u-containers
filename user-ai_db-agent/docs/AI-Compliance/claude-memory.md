# Claude Memory — How Auto-Memory Works

> How Claude Code's persistent memory system works, where it lives, and how it relates to CLAUDE.md.

---

## What is Auto-Memory?

Claude Code has a persistent memory directory that survives across sessions. The AI reads and writes to it to accumulate knowledge about the project and user preferences over time.

---

## Memory Location

```
~/.claude/projects/-data-data-com-termux-nix-files-home/memory/
└── MEMORY.md    ← Always loaded into system prompt (first 200 lines)
```

The path is derived from the working directory hash. Since all sessions start from `~`, this is the single memory directory for all work.

---

## MEMORY.md vs CLAUDE.md

| Aspect | CLAUDE.md | MEMORY.md |
|--------|-----------|-----------|
| **Who writes it** | Human (Diego) | AI (Claude) + Human |
| **Deployed via** | Nix home-manager (read-only symlink) | Direct file (read-write) |
| **Content** | Stack definitions, rules, standards | Learned patterns, gotchas, debugging insights |
| **Persistence** | Survives rebuild (nix store) | Survives sessions (filesystem) |
| **Loaded as** | System context (full file) | System context (first 200 lines) |
| **Edit location** | `~/git/cloud-unix/.../dotfiles/claude/CLAUDE.md` | Direct at `~/.claude/projects/.../memory/MEMORY.md` |

**Key difference**: CLAUDE.md is **prescriptive** (rules to follow), MEMORY.md is **descriptive** (things learned).

---

## Current MEMORY.md Contents

The memory tracks accumulated knowledge across sessions:

### What's in it
- **Key projects** — Repo locations and purposes
- **Build system** — Universal build.sh patterns, config parser, dev server chain
- **Shell rules** — `command -v` not `which`, OCI CLI warnings
- **Common gotchas** — `set -e` traps, SSH config detection, git remote patterns
- **Home Manager** — All 6 VM deployments, GHA workflow, swap workarounds, WireGuard gotcha
- **Rust builds** — GCP micro VM constraints (`--jobs 1`, `lto = false`)
- **Docker + WireGuard** — nftables, Mailu port config, Authelia SMTP setup
- **Project archetypes** — Which projects use Vite, SvelteKit, Sass+esbuild, etc.

### What should go in MEMORY.md
- Stable patterns confirmed across multiple sessions
- Debugging solutions that took effort to find
- User preferences for workflow and communication
- Key architectural decisions and file paths

### What should NOT go in MEMORY.md
- Session-specific context (current task, in-progress work)
- Incomplete or unverified information
- Anything that duplicates CLAUDE.md instructions
- Speculative conclusions from reading a single file

---

## Guidelines for AI

1. **Check memory before starting work** — Previous sessions may have solved similar problems
2. **Record non-obvious discoveries** — If debugging took multiple steps, save the solution
3. **Keep it under 200 lines** — Content after line 200 is truncated from the system prompt
4. **Use topic files for details** — Create `debugging.md`, `patterns.md` etc. and link from MEMORY.md
5. **Update or remove stale entries** — If something turns out wrong, fix it
6. **Organize by topic, not chronology** — Semantic grouping over date-based entries
7. **Explicit user requests** — When user says "remember X", save it immediately

---

## Relationship to claude-guard.sh

Memory and guard hooks are complementary:
- **MEMORY.md** teaches the AI what it learned (soft guidance)
- **CLAUDE.md** tells the AI what rules to follow (firm guidance)
- **claude-guard.sh** enforces the rules the AI forgets (hard enforcement)

The progression: Memory informs → CLAUDE.md instructs → Hooks enforce.
