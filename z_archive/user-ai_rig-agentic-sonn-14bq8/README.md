# Rig Intelligence Framework

**Status**: 🚧 Planning Phase
**Target**: oci-apps (3 vCPU, 16GB, aarch64)
**Port**: 8080

---

## Overview

Rig is the central nervous system for the personal cloud infrastructure. It orchestrates three macro workflows:

1. **Self-Healing & Self-Protection** - Autonomous maintenance, anomaly detection, sandboxed fixes
2. **KG Maintenance** - Daily indexing (small LLM), weekly reviews (Opus)
3. **Agentic Framework** - API gateway for KG access, multi-agent orchestration

## Architecture

```
Rig Orchestrator (Rust + Rig framework)
    ↓
SurrealDB Hybrid KG (Vector + Graph)
    ↓
Ollama 14B (vast.ai) + nomic-embed-text
```

## Quick Start

### Prerequisites

- Rust 1.75+ (installed via home-manager on oci-apps)
- SurrealDB running on :8001
- vast.ai Ollama instance (or local fallback)
- SSH key: `~/git/cloud-vault/A0_keys/ssh/rig_id_ed25519`

### Build & Deploy

```bash
cd ~/git/cloud-infra/a_solutions/bc-obs_rig
cargo test --release
./build.sh ship  # Build on oci-apps (aarch64)
```

### Enable Service

```bash
ssh oci-apps "sudo systemctl enable --now rig-orchestrator.service"
```

### Verify

```bash
curl http://10.0.0.6:8080/rig/heal/status
# Expected: {"status": "healthy", "workflows": [...]}
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/rig/heal/status` | GET | Current health state |
| `/rig/heal/trigger` | POST | Manual health check |
| `/rig/kg/query` | POST | Hybrid GraphRAG query |
| `/rig/kg/blast_radius/:entity` | GET | Impact analysis |
| `/rig/agent/execute` | POST | Multi-step agent execution |
| `/rig/workflows` | GET | List active workflows |

## Configuration

Edit `config.toml`:

```toml
[kg]
url = "http://localhost:8001"

[ollama]
url = "http://vast-ollama:11434/v1"
model = "qwen2.5:14b-instruct-q4_K_M"

[self_healing]
check_interval_sec = 300
```

## Documentation

- **[Master Plan](./docs/MASTERPLAN.md)** - Complete implementation plan (6 weeks)
- **[API Reference](./docs/API.md)** - REST API documentation (TODO)
- **[Workflows](./docs/WORKFLOWS.md)** - Detailed workflow logic (TODO)

## Development

### Project Structure

```
src/
├── main.rs                    # Entry point, HTTP server
├── workflows/
│   ├── self_healing.rs        # Workflow 1
│   ├── kg_maintenance.rs      # Workflow 2
│   └── agentic_framework.rs   # Workflow 3
├── ops/                       # Individual pipeline operations
├── kg/                        # SurrealDB client, queries
└── agents/                    # Ollama client, tool executor
```

### Run Tests

```bash
cargo test
```

### Run Locally (Desktop)

```bash
# Requires SSH tunnel to oci-apps SurrealDB
ssh -L 8001:localhost:8001 oci-apps -N &
cargo run
```

## Monitoring

```bash
# Service logs
ssh oci-apps "journalctl -u rig-orchestrator -f"

# Check cron jobs
ssh oci-apps "crontab -l"

# Query audit log
ssh oci-apps "surreal sql --conn http://localhost:8001"
# > SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT 10;
```

## Troubleshooting

**Issue**: Rig not responding
```bash
ssh oci-apps "systemctl restart rig-orchestrator"
```

**Issue**: Ollama unreachable
- Check vast.ai instance status
- Fallback to local CPU inference (automatic)

**Issue**: Self-healing in loop
- Check `max_retries` in config
- Manually resolve issue, reset via API

## License

Private - Diego Nepomuceno Marcos

## Contact

GitHub Issues: https://github.com/diegonmarcos/cloud-infra
