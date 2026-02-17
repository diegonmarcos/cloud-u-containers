# Ollama GPU Service — GCP Spot T4 (primary) + Vast.ai On-Demand (fallback)

## Overview

Deploy Ollama LLM server with DeepSeek and Qwen 14B models (Q4/Q8 quantizations) on a GCP Spot T4 GPU VM as primary, with Vast.ai on-demand as fallback. Access via WireGuard only (no Caddy/public domain). New category `ad-agi_` for AI/ML services.

## Architecture

```
                    WireGuard Mesh (10.0.0.x)
                           │
              ┌────────────┼────────────┐
              │            │            │
         gcp-ollama   gcp-proxy    oci-apps-*
         10.0.0.10    10.0.0.1     10.0.0.x
              │
     ┌────────┴────────┐
     │  NVIDIA T4 GPU  │
     │  16GB VRAM      │
     │                 │
     │  ┌───────────┐  │
     │  │  Ollama   │  │
     │  │  :11434   │  │
     │  └───────────┘  │
     └─────────────────┘
```

## Models

| Model | Quant | VRAM | Use Case |
|-------|-------|------|----------|
| deepseek-r1:14b | Q4_K_M | ~8GB | Default reasoning |
| deepseek-r1:14b-q8_0 | Q8 | ~14GB | High-quality reasoning |
| qwen2.5:14b | Q4_K_M | ~8GB | General purpose |
| qwen2.5:14b-q8_0 | Q8 | ~14GB | High-quality general |

## Cost Estimate

| Component | Monthly (4h/day) |
|-----------|-----------------|
| GCP Spot T4 GPU | ~$17 |
| GCP Spot n1-std-4 VM | ~$5 |
| GCP Boot Disk 50GB | ~$2 |
| **Total (primary)** | **~$24/mo** |
| Vast.ai fallback (if used) | ~$12-18/mo |

## GCP VM Specs

- **Machine**: n1-standard-4 (4 vCPUs, 15GB RAM)
- **GPU**: NVIDIA Tesla T4 (16GB VRAM)
- **Provisioning**: Spot (preemptible, ~70% cheaper)
- **Disk**: 50GB SSD
- **Zone**: us-central1-a
- **WireGuard IP**: 10.0.0.10

## Deployment

```bash
# Build + deploy (after VM is created)
cd ~/git/cloud/a_solutions/container-nix/ad-agi_ollama
./build.sh ship

# Pull models on VM
ssh gcp-ollama "docker exec ollama ollama pull deepseek-r1:14b"
ssh gcp-ollama "docker exec ollama ollama pull qwen2.5:14b"

# Test
curl http://10.0.0.10:11434/api/tags
curl http://10.0.0.10:11434/api/generate -d '{"model":"deepseek-r1:14b","prompt":"hello","stream":false}'
```

## Vast.ai Fallback

If GCP spot VM is preempted or unavailable:
1. `fallback.sh` checks GCP VM health
2. Searches Vast.ai for T4/RTX A4000 instances
3. Creates instance, deploys ollama via SSH
4. Uses SSH tunnel or WireGuard for access
5. Requires VASTAI_API_KEY in secrets.yaml

## VM Setup Checklist (separate session)

- [ ] Create GCP spot VM with T4 GPU
- [ ] Install NVIDIA Container Toolkit + Docker
- [ ] Configure WireGuard (10.0.0.10)
- [ ] Add SSH alias `gcp-ollama` to vault config
- [ ] Update config.json with actual IP
- [ ] Deploy via `./build.sh ship`
- [ ] Pull models
- [ ] Verify GPU inference
