# Profile: Debug / Mid (Sonnet)

> `CLAUDE_MODE=debug CLAUDE_MODEL=sonnet`

## Skills Available

- Senior Front-End Developer
- Senior Designer
- Junior Software Engineer
- Junior Ops

## Enforcement Output

Relaxed + mid-tier restrictions. Standard BLOCKs → WARN. WARNs → allow. Junior gate still active for infra.

### Critical BLOCK (still exit 2)

Same as Debug/Senior — critical BLOCKs never relaxed.

### Standard BLOCK → WARN (downgraded)

Same as Debug/Senior — `nix build`, `nixos-rebuild`, etc. become warnings.

### WARN → Allowed (skipped)

Same as Debug/Senior — all WARNs silently allowed.

### Junior Gate (still exit 2 — not relaxed by debug mode)

| Pattern | Message |
|---------|---------|
| `build.sh ship` | Mid model: full deploy requires Senior skill |
| `vm_start\|vm_stop\|vm_reset` | Mid model: VM lifecycle requires Senior skill |
| `sops` | Mid model: secrets management requires Senior skill |
| Edit `flake.nix` in `cloud/` | Mid model: cloud architecture requires Senior skill |

## Use Cases

- Debugging front-end builds with raw `npm run dev`
- Testing a dependency with `npm install` without going through `deploy.sh deps`
- Running `nix build` to check flake evaluation for a front-end project

## Still Blocked (even in debug)

- All critical BLOCKs (same as any profile)
- All junior gate restrictions (infra operations)
- Debug mode relaxes enforcement level, NOT skill access
