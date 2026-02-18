# Per-Project Rules: unix/

> `~/git/unix/` — NixOS host config, home-manager (desktop + termux), system flakes

## Project-Specific BLOCKs

| Pattern | Message |
|---------|---------|
| `nixos-rebuild switch` directly | Use `~/git/unix/aa_nixos-surface_host/build.sh switch` |
| `home-manager switch` directly | Use `build.sh switch` from the flake directory |
| `nix-on-droid switch` directly | Use `~/git/unix/bb_flakes_termux/build.sh switch` |
| Edit `~/.claude/CLAUDE.md` | Nix store symlink — edit `src/modules/dotfiles/claude/CLAUDE.md` |
| Edit `~/.mcp.json` | Nix store symlink — edit `src/modules/dotfiles/claude/mcp.json` |
| Edit `~/.claude/settings.json` | Nix store symlink — edit source in dotfiles/claude/ |

## Project-Specific WARNs

| Pattern | Message |
|---------|---------|
| `nix-env -i` | Add to `home.packages` in the flake instead |
| Modify `flake.lock` manually | Use `nix flake update` via `build.sh` |

## Source-of-Truth Mapping

| Deployed file | Termux source | Desktop source |
|---------------|---------------|----------------|
| `~/.claude/CLAUDE.md` | `bb_flakes_termux/src/modules/dotfiles/claude/CLAUDE.md` | `ba_flakes_desktop/src/modules/dotfiles/claude/CLAUDE.md` |
| `~/.mcp.json` | `bb_flakes_termux/src/modules/dotfiles/claude/mcp.json` | `ba_flakes_desktop/src/modules/dotfiles/claude/mcp.json` |
| `~/.claude/settings.json` | *(not deployed)* | `ba_flakes_desktop/src/modules/dotfiles/claude/settings.json` |
| `~/.claude/hooks/claude-guard.sh` | `bb_flakes_termux/src/modules/dotfiles/claude/claude-guard.sh` | `ba_flakes_desktop/src/modules/dotfiles/claude/claude-guard.sh` |

## Build Commands

| Flake | Command |
|-------|---------|
| NixOS host | `~/git/unix/aa_nixos-surface_host/build.sh` (options: r/b/t) |
| Desktop home-manager | `~/git/unix/ba_flakes_desktop/build.sh switch` |
| Termux home-manager | `~/git/unix/bb_flakes_termux/build.sh switch` |

## Key Constraint

Desktop and Termux CLAUDE.md are **independent files**. Changes to one do NOT propagate to the other. Must be manually kept in sync.
