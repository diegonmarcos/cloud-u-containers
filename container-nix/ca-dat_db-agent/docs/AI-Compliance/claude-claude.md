# CLAUDE.md — Architecture and Deployment

> How CLAUDE.md works in Diego's system: source, deployment, structure, and maintenance.

---

## What is CLAUDE.md?

The master context file loaded into every Claude Code session. It contains:
- Stack definitions (Unix, Cloud, Security, Front-end, Ops)
- Build system rules and conventions
- Code standards (TypeScript, Svelte 5, Vue 3, SCSS)
- MCP server and API references
- Skills definitions

---

## Source-of-Truth Locations

CLAUDE.md exists in **two separate sources** (desktop and termux), deployed via home-manager:

| Environment | Source file (EDIT THIS) | Deployed to (READ-ONLY) |
|-------------|------------------------|------------------------|
| **Desktop** | `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| **Termux** | `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/CLAUDE.md` | `~/.claude/CLAUDE.md` |

### Other deployed files

| File | Desktop source | Termux source |
|------|---------------|---------------|
| `~/.mcp.json` | `.../ba_flakes_desktop/src/modules/dotfiles/claude/mcp.json` | `.../bb_flakes_termux/src/modules/dotfiles/claude/mcp.json` |
| `~/.claude/settings.json` | `.../ba_flakes_desktop/src/modules/dotfiles/claude/settings.json` | *(not deployed)* |
| `~/.claude/statusline-command.sh` | `.../ba_flakes_desktop/src/modules/dotfiles/claude/statusline-command.sh` | `.../bb_flakes_termux/src/modules/dotfiles/claude/statusline-command.sh` |

---

## Deployment Mechanism

Home-manager links source files into the nix store, then symlinks them to `~/`:

```nix
# In common.nix (desktop) or flake.nix (termux):
home.file.".claude/CLAUDE.md".source = ./dotfiles/claude/CLAUDE.md;
home.file.".mcp.json".source = ./dotfiles/claude/mcp.json;
home.file.".claude/settings.json".source = ./dotfiles/claude/settings.json;
home.file.".claude/statusline-command.sh" = {
  source = ./dotfiles/claude/statusline-command.sh;
  executable = true;
};
```

**Result**: `~/.claude/CLAUDE.md` is a symlink to `/nix/store/<hash>-CLAUDE.md` — **read-only**.

### Update workflow

1. Edit the source file in `~/git/unix/b{a,b}_flakes_{desktop,termux}/src/modules/dotfiles/claude/`
2. Run `./build.sh switch` from the flake directory
3. Home-manager updates the nix store symlink
4. Next Claude Code session loads the updated content

---

## Structure of CLAUDE.md

```
# Diego's Master Context for Claude Agents

## STACK
├── Section A: UNIX (NixOS & System Configuration)
│   ├── System overview, key paths, build commands
│   └── Agent-essential notes (impermanence, LUKS, initrd)
├── Section B: CLOUD INFRASTRUCTURE
│   ├── VMs (5 VMs, always-on vs paid)
│   ├── Networking (Cloudflare → Caddy → WireGuard → VM)
│   ├── Active services (15+ services with domains)
│   └── Bearer token auth
├── Section C: SECURITY & CREDENTIALS
│   ├── Vault structure (SSH keys, API tokens, passwords)
│   └── Security stack layers
├── Section D: FRONT-END DEVELOPMENT
│   ├── Build system, code standards
│   ├── TypeScript strict, Svelte 5 runes, Vue 3 composition
│   ├── SCSS rules (ITCSS, Golden Mixins)
│   └── Matomo analytics requirement
├── Section E: OPS & BUILD SYSTEM
│   ├── CRITICAL: Nix Way (flakes in repo, build.sh only)
│   ├── Build patterns per repo (front, cloud, unix)
│   └── Cloud service structure (mandatory)
└── Section F: OTHERS (Quick Reference)

## SKILLS & MCPs
├── Skills (7 skill levels)
├── MCP: cloud-infra (44 tools, architecture)
└── APIs (Rust, Flask, Crawlee)
```

---

## Synchronization Problem

Desktop and Termux CLAUDE.md are **independent files**. Changes to one do NOT propagate to the other. They must be manually kept in sync.

Possible improvements:
- Symlink one to the other within the git repo
- Use a shared source file imported by both flakes
- Generate both from a single template

---

## Why the AI Ignores Rules

Even with CLAUDE.md loaded, the AI sometimes violates rules because:

1. **Context dilution** — Long files get lower attention weight on specific rules
2. **Training data dominance** — Svelte 4, Vue Options API, `any` type are in training data at much higher frequency
3. **No enforcement** — CLAUDE.md is advisory; nothing stops the AI from writing `style=""`

**Solution**: `claude-guard.sh` hooks (see `claude-guard.md`) enforce the critical rules at the tool level, before the code is written.
