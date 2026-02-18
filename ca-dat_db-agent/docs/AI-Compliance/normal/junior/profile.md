# Profile: Normal / Junior (Haiku)

> `CLAUDE_MODE=normal CLAUDE_MODEL=haiku`

## Skills Available

- Junior Software Engineer
- Junior Ops

## Enforcement Output

Maximum enforcement. All 33 rules + junior gate = most restricted profile. WARNs become BLOCKs.

### Critical BLOCK (always exit 2)

Same as Senior — all critical BLOCKs apply identically.

### Standard BLOCK (exit 2)

Same as Senior — all standard BLOCKs apply identically.

### WARN → BLOCK (upgraded for Junior)

All WARN rules are upgraded to BLOCK for Haiku:

| # | Pattern | Message (upgraded) |
|---|---------|---------|
| 5 | `npm run build\|dev` | BLOCKED: Junior model — use `./build.sh` |
| 6 | `npm install` in subdir | BLOCKED: Junior model — use `deploy.sh deps` |
| 7 | `ssh.*docker compose` | BLOCKED: Junior model — use `build.sh ship` |
| 24 | `nix-env -i` | BLOCKED: Junior model — add to flake |
| 25 | `pip install` | BLOCKED: Junior model — add to flake |
| 26 | `cargo install` | BLOCKED: Junior model — add to flake |
| 27 | `npm install -g` | BLOCKED: Junior model — add to flake |
| 28 | `apt install` | BLOCKED: Junior model — use nix flakes |
| 31 | `ssh.*sed.*-i` | BLOCKED: Junior model — edit Nix source |
| 17 | `: any` in .ts | BLOCKED: Junior model — define proper type |

### Junior Gate (exit 2 — full restrictions)

| Pattern | Message |
|---------|---------|
| `build.sh ship` | Junior model: full deploy requires Senior skill |
| `build.sh compose` | Junior model: container restart requires Senior skill |
| `vm_start\|vm_stop\|vm_reset` | Junior model: VM lifecycle requires Senior skill |
| `sops` | Junior model: secrets management requires Senior skill |
| Edit `flake.nix` (any repo) | Junior model: flake changes require Senior skill |
| Edit `build.sh` (any repo) | Junior model: build system changes require Senior skill |
| Edit `docker-compose.yml` | Junior model: compose config requires Senior skill |
| Edit `*.nix` in `home-manager/` | Junior model: VM config requires Senior skill |
| `ssh` to any VM | Junior model: SSH access requires Senior skill |

## Allowed Operations

- Read files (any repo)
- Edit application source code (`.ts`, `.svelte`, `.vue`, `.scss`, `.html`)
- Run local tests
- `build.sh build` (local build only, no deploy)
- `build.sh dev` (local dev server)
- Docker logs via MCP (`docker_logs`)
- Health checks via MCP (`health_status`, `health_declared`)
- `git status`, `git diff`, `git log` (read-only git)

## Blocked Operations

- Everything not in "Allowed" above
- All SSH, all deploys, all VM operations, all secrets, all flake edits
