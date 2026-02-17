# Profile: Debug / Junior (Haiku)

> `CLAUDE_MODE=debug CLAUDE_MODEL=haiku`

## Skills Available

- Junior Software Engineer
- Junior Ops

## Enforcement Output

Debug mode relaxes enforcement level, but junior gate is never relaxed. This is the most permissive junior profile but still highly restricted.

### Critical BLOCK (still exit 2)

Same as all profiles — never relaxed.

### Standard BLOCK → WARN (downgraded by debug)

| # | Pattern | Message |
|---|---------|---------|
| 1 | `nix build\|run\|develop` | WARNING: Consider `./build.sh build` |
| 2 | `nixos-rebuild` | WARNING: Consider `build.sh switch` |
| 3 | `home-manager switch` | WARNING: Consider `build.sh switch` |

### WARN → Allowed (skipped by debug)

All WARN rules silently allowed (unlike Normal/Junior where WARNs are upgraded to BLOCKs).

### Junior Gate (still exit 2 — never relaxed)

Full junior restrictions remain even in debug mode:

| Pattern | Message |
|---------|---------|
| `build.sh ship` | Junior model: full deploy requires Senior skill |
| `build.sh compose` | Junior model: container restart requires Senior skill |
| `vm_start\|vm_stop\|vm_reset` | Junior model: VM lifecycle requires Senior skill |
| `sops` | Junior model: secrets management requires Senior skill |
| Edit `flake.nix` | Junior model: flake changes require Senior skill |
| Edit `build.sh` | Junior model: build system changes require Senior skill |
| `ssh` to any VM | Junior model: SSH access requires Senior skill |

## Key Difference from Normal/Junior

| Rule type | Normal/Junior | Debug/Junior |
|-----------|---------------|--------------|
| Critical BLOCK | BLOCK | BLOCK |
| Standard BLOCK | BLOCK | **WARN** |
| WARN | **BLOCK** (upgraded) | **allow** (skipped) |
| Junior gate | BLOCK | BLOCK |

Debug mode only relaxes enforcement level (standard blocks + warns). Skill access (junior gate) is immutable.

## Use Cases

- Haiku debugging a local build issue — can run `nix build` (warned, not blocked)
- Testing with `npm install` — allowed (warn skipped)
- Still cannot touch infra, VMs, secrets, or deploy
