# Ollama Service — Implementation Tasks

## Phase 1: Service Skeleton (this session)

- [x] Create `ad-agi_ollama/` directory structure
- [x] Copy `build.sh` from template (bb-sec_authelia)
- [x] Create `build.json` with deploy config
- [x] Write `docs/plan.md`
- [x] Write `docs/tasks.md`
- [x] Write `src/flake.nix` (docker-compose + scripts)
- [x] Update `config.json` — add gcp-T4-p_0 VM + update ollama service
- [x] Update root `flake.nix` — add ad-agi_ollama input
- [x] Git commit + push

## Phase 2: GCP VM Creation (separate session)

- [ ] Create GCP Spot T4 VM via gcloud CLI
- [ ] Get external IP, update config.json
- [ ] Install Docker on VM
- [ ] Install NVIDIA Container Toolkit on VM
- [ ] Verify GPU: `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`
- [ ] Generate WireGuard keypair on VM
- [ ] Assign WireGuard IP 10.0.0.10
- [ ] Add peer to all existing VMs' WireGuard configs
- [ ] Update hickory-dns for `ollama.internal` → 10.0.0.10
- [ ] Add SSH alias `gcp-ollama` to vault SSH configs

## Phase 3: Deploy & Test (separate session)

- [ ] Run `./build.sh ship` from local
- [ ] Pull models: deepseek-r1:14b, qwen2.5:14b
- [ ] Test via WireGuard: `curl http://10.0.0.10:11434/api/tags`
- [ ] Test inference: generate request via API
- [ ] Verify GPU usage: `nvidia-smi` inside container
- [ ] Pull Q8 variants if VRAM allows

## Phase 4: Vast.ai Fallback (optional, separate session)

- [ ] Create sops-encrypted secrets.yaml with VASTAI_API_KEY
- [ ] Install vastai CLI (pip or nix)
- [ ] Write/test fallback.sh script
- [ ] Test: stop GCP VM, run fallback, verify Vast.ai takes over
