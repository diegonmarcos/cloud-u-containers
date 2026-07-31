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

## Phase 2: GCP VM Creation

- [x] Create GCP Spot T4 VM via gcloud CLI (IP: 34.57.36.41)
- [x] Get external IP, update config.json
- [x] Install Docker on VM
- [x] Install NVIDIA Container Toolkit on VM
- [x] Verify GPU: Tesla T4 15360 MiB
- [x] Generate WireGuard keypair on VM (pubkey: PN6ddzDi...)
- [x] Assign WireGuard IP 10.0.0.8
- [x] Add peer to all existing VMs' WireGuard configs (via home-manager GHA)
- [x] Install Nix on VM + configure flakes + trusted-users
- [x] Deploy home-manager (idle-shutdown 1h + daily-shutdown 1AM + WireGuard)
- [x] Add SSH alias `gcp-ollama` to vault SSH configs
- [x] Set GHA secrets: GCP_T4_HOST, GCP_T4_USER, GCP_T4_SSH_KEY
- [ ] Update hickory-dns for `ollama.internal` → 10.0.0.8

## Phase 3: Deploy & Test

- [x] Deploy Ollama container with GPU support
- [x] Pull models: deepseek-r1:14b (9.0GB), qwen2.5:14b (9.0GB)
- [x] Test via WireGuard: `curl http://10.0.0.8:11434/api/tags` — working
- [x] Test inference: deepseek-r1:14b responds correctly
- [x] Verify WireGuard mesh: hub handshake active
- [ ] Redeploy via `build.sh ship` (bind to WG IP instead of 0.0.0.0)
- [ ] Verify GPU usage: `nvidia-smi` inside container during inference
- [ ] Pull Q8 variants if VRAM allows

## Phase 4: Vast.ai Fallback (optional, separate session)

- [ ] Create sops-encrypted secrets.yaml with VASTAI_API_KEY
- [ ] Install vastai CLI (pip or nix)
- [ ] Write/test fallback.sh script
- [ ] Test: stop GCP VM, run fallback, verify Vast.ai takes over
