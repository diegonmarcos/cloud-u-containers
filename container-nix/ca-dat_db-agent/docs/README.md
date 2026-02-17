# Self-Healing: Claude Compliance Docs

Documentation for enforcing CLAUDE.md rules and preventing Claude from bypassing the source-of-truth pipeline.

## Index

| File | Description |
|------|-------------|
| [Compliance-Plan.md](AI-Compliance/Compliance-Plan.md) | 5-layer compliance enforcement plan — after Claude ignored CLAUDE.md 4 times during KG+Rig deployment |
| [Compliance-Tasks.md](AI-Compliance/Compliance-Tasks.md) | Actionable task checklist extracted from the plan, with status tracking |
| [claude-claude.md](AI-Compliance/claude-claude.md) | CLAUDE.md architecture — source locations, deployment via home-manager, structure and maintenance |
| [claude-guard.md](AI-Compliance/claude-guard.md) | Hook rules for `claude-guard.sh` — BLOCK/WARN tiers that enforce CLAUDE.md via pre-tool validation |
| [claude-mcp.md](AI-Compliance/claude-mcp.md) | MCP integration — how cloud-infra MCP server connects to Claude Code and what tools it provides |
| [claude-memory.md](AI-Compliance/claude-memory.md) | Auto-memory system — how persistent memory works, where it lives, how it relates to CLAUDE.md |
