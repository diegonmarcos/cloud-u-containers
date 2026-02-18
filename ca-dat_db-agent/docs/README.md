# Self-Healing: Claude Compliance Docs

Documentation for enforcing CLAUDE.md rules and preventing Claude from bypassing the source-of-truth pipeline.

## Index

| File | Description |
|------|-------------|
| [Compliance-Plan.md](AI-Compliance/Compliance-Plan.md) | 6-layer compliance enforcement plan — after Claude ignored CLAUDE.md 4 times during KG+Rig deployment |
| [Compliance-Tasks.md](AI-Compliance/Compliance-Tasks.md) | Actionable task checklist extracted from the plan, with status tracking |
| [claude-claude.md](AI-Compliance/claude-claude.md) | CLAUDE.md architecture — source locations, deployment via home-manager, structure and maintenance |
| [claude-guard.md](AI-Compliance/claude-guard.md) | Hook rules for `claude-guard.sh` — BLOCK/WARN tiers that enforce CLAUDE.md via pre-tool validation |
| [claude-mcp.md](AI-Compliance/claude-mcp.md) | MCP integration — how cloud-infra MCP server connects to Claude Code and what tools it provides |
| [claude-memory.md](AI-Compliance/claude-memory.md) | Auto-memory system — how persistent memory works, where it lives, how it relates to CLAUDE.md |

## Profile System

Enforcement output specs per profile (model tier × mode):

| Profile | Description |
|---------|-------------|
| [normal/senior](AI-Compliance/normal/senior/profile.md) | Opus — all skills, full enforcement (17 BLOCK + 16 WARN) |
| [normal/mid](AI-Compliance/normal/mid/profile.md) | Sonnet — Front-End + Designer + Junior, standard enforcement |
| [normal/junior](AI-Compliance/normal/junior/profile.md) | Haiku — Junior only, maximum enforcement (WARNs → BLOCKs) |
| [debug/senior](AI-Compliance/debug/senior/profile.md) | Opus debug — critical BLOCKs stay, others relaxed |
| [debug/mid](AI-Compliance/debug/mid/profile.md) | Sonnet debug — relaxed enforcement, junior gate still active |
| [debug/junior](AI-Compliance/debug/junior/profile.md) | Haiku debug — relaxed enforcement, junior gate immutable |

## Per-Project Rules

| Project | Description |
|---------|-------------|
| [cloud/](AI-Compliance/per-project/cloud/rules.md) | Service structure, secrets pipeline, build.sh enforcement |
| [unix/](AI-Compliance/per-project/unix/rules.md) | Source-of-truth mapping, flake build commands |
| [vault/](AI-Compliance/per-project/vault/rules.md) | Credential protection, sensitive paths |
| [front/](AI-Compliance/per-project/front/rules.md) | Code standards (Svelte 5, Vue 3, TS strict, SCSS), archetypes |
