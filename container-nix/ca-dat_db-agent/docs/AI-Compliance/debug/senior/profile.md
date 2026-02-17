# Profile: Debug / Senior (Opus)

> `CLAUDE_MODE=debug CLAUDE_MODEL=opus`

## Skills Available

All skills (same as Normal/Senior).

## Enforcement Output

Relaxed enforcement. Critical BLOCKs remain. Standard BLOCKs downgrade to WARN. WARNs are skipped.

### Critical BLOCK (still exit 2 — never relaxed)

| # | Pattern | Message |
|---|---------|---------|
| 29 | `which` | Use `command -v` |
| 30 | `ssh.*echo.*>.*\.secrets` | Create `src/secrets.yaml` + sops |
| 10a | Edit `~/.claude/CLAUDE.md` | Edit source in `~/git/unix/` flakes |
| 10b | Edit `~/.mcp.json` | Edit source in `~/git/unix/` flakes |
| 11 | Edit `*/dist/*` | Edit source in `src/` |
| 12 | Edit `/nix/store/*` | Nix store is immutable |
| 16 | `style=""` in .html/.svelte/.vue | No inline CSS |
| 18 | `export let` in .svelte | Svelte 5 runes |
| 20 | `on:click` in .svelte | Svelte 5: `onclick` |

### Standard BLOCK → WARN (downgraded in debug)

| # | Pattern | Message (now warning) |
|---|---------|---------|
| 1 | `nix build\|run\|develop` | WARNING: Consider `./build.sh build` |
| 2 | `nixos-rebuild` | WARNING: Consider `build.sh switch` |
| 3 | `home-manager switch` | WARNING: Consider `build.sh switch` |
| 4 | `nix-on-droid switch` | WARNING: Consider `build.sh switch` |

### WARN → Allowed (skipped in debug)

All 16 WARN rules are silently allowed:
- `nix-env -i`, `npm install`, `pip install`, etc. — no warning
- `ssh.*docker compose`, `ssh.*sed` — no warning
- Code quality (`: any`, `$:` reactive, etc.) — no warning

### Junior Gate

Not active — Opus has full access.

## Use Cases

- Debugging a broken service by running raw `nix build` to test flake evaluation
- Using `home-manager switch` directly to test a config change before committing
- Running `npm install` to quickly test a dependency
- Using `docker compose up -d` on a VM to restart a crashed container

## Still Blocked (even in debug)

- Creating `.secrets` manually on VMs (always critical)
- Editing deployed nix store/CLAUDE.md files (immutable by design)
- Using `which` (genuinely doesn't exist)
- Inline CSS / old Svelte syntax (compile-breaking)
