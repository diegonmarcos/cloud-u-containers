# Profile: Normal / Mid (Sonnet)

> `CLAUDE_MODE=normal CLAUDE_MODEL=sonnet`

## Skills Available

- Senior Front-End Developer
- Senior Designer
- Junior Software Engineer
- Junior Ops

## Enforcement Output

All 33 rules active. Standard + Critical BLOCKs enforced. Junior gate active for infra operations.

### Critical BLOCK (always exit 2)

Same as Senior — all critical BLOCKs apply identically.

### Standard BLOCK (exit 2)

Same as Senior — all standard BLOCKs apply identically.

### WARN (stderr, allow through)

Same as Senior — all WARNs apply identically.

### Junior Gate (exit 2 — Sonnet restrictions)

| Pattern | Message |
|---------|---------|
| `build.sh ship` | Mid model: `build.sh ship` requires Senior Cloud Architect skill |
| `vm_start\|vm_stop\|vm_reset` | Mid model: VM lifecycle requires Senior skill |
| `sops -e\|sops -d` | Mid model: secrets management requires Senior skill |
| Edit `flake.nix` in `cloud/` | Mid model: cloud architecture changes require Senior skill |
| Edit `modules/*.nix` in `home-manager/` | Mid model: VM config changes require Senior skill |

## Allowed Operations

- Front-end builds (`build.sh build`, `build.sh dev`)
- Code changes in `~/git/front/` (all projects)
- SCSS/TypeScript/Svelte/Vue development
- Docker logs and health checks (read-only infra)
- `build.sh compose` (restart containers, no full deploy)
- All front-end MCP tools (`front_*`)

## Blocked Operations

- `build.sh ship` (full deploy to VM)
- VM start/stop/reset
- Secrets encryption/decryption
- Cloud flake modifications
- Home-manager config changes
