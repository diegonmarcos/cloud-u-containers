# Tools Comparison: Current vs Home Manager

## Current State (System-Installed)

| Tool | gcp-proxy | oci-flex | oci-mail | oci-analytics | Notes |
|------|-----------|----------|----------|---------------|-------|
| **sops** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **age** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **jq** | ❌ | ✅ /usr/bin | ✅ /usr/bin | ✅ /usr/bin | Missing on gcp-proxy |
| **yq** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **docker** | ✅ /usr/bin | ✅ /usr/bin | ✅ /usr/bin | ✅ /usr/bin | All have it |
| **docker-compose** | ✅ /usr/local/bin | ❌ | ✅ /usr/local/bin | ✅ /usr/local/bin | Missing on oci-flex |
| **rsync** | ✅ /usr/bin | ✅ /usr/bin | ❌ | ❌ | Missing on oci-mail, oci-analytics |
| **rclone** | ❌ | ✅ /usr/bin | ❌ | ❌ | Only on oci-flex |
| **gh** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **ripgrep** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **fd** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **bat** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **htop** | ? | ? | ? | ? | Likely present |
| **btop** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |
| **ncdu** | ❌ | ❌ | ❌ | ❌ | Missing on all VMs |

### Summary
- **Inconsistent:** Tools vary widely across VMs
- **Missing critical:** sops, age, yq missing everywhere
- **Build tools:** jq missing on gcp-proxy (breaks build.sh)
- **Transfer tools:** rsync/rclone availability varies

## After Home Manager Deployment

All VMs will have **consistent** tool availability:

### Core Tools (All VMs)
```
✅ sops              # Secrets encryption/decryption
✅ age               # Age encryption for sops
✅ jq                # JSON processing
✅ yq-go             # YAML processing
✅ rsync             # File synchronization
✅ rclone            # Cloud file transfer
✅ curl, wget        # HTTP clients
✅ netcat            # Network debugging
✅ git, gh           # Version control + GitHub CLI
✅ ripgrep, fd       # Fast search tools
✅ bat               # Cat with syntax highlighting
✅ htop, btop        # System monitoring
✅ ncdu              # Disk usage analyzer
✅ tree              # Directory tree viewer
✅ lsof, iftop       # Network monitoring
✅ gzip, unzip, zip  # Compression tools
```

### Docker/Compose
- Not managed by home-manager (assumed system-installed)
- Comment in configs if needed

### VM-Specific Additions

**oci-mail:**
- `swaks` - SMTP testing tool

### Environment Setup

All VMs get:
- Custom colored prompts (shows hostname)
- Docker aliases (dps, dlogs, dstop, etc.)
- Git configuration (name, email, branch defaults)
- History settings (10k lines, deduplication)
- SOPS_AGE_KEY_FILE auto-detection
- WireGuard IP exports (oci-* VMs)

## Benefits

### 1. Consistency
- Same tools on all VMs
- No "works on my machine" issues
- Predictable build.sh behavior

### 2. Declarative
- Tools defined in version control
- Easy to add/remove tools
- Reproducible environments

### 3. No Conflicts
- Nix packages isolated in /nix/store
- Won't interfere with system packages
- Multiple versions can coexist

### 4. Easy Updates
```bash
cd ~/git/cloud/a_solutions/home-manager
nix flake update          # Update package versions
./build.sh ship          # Deploy to all VMs
```

## Deployment

### Prerequisites (One-time per VM)

Each VM needs Nix installed:
```bash
# On each VM:
curl -L https://nixos.org/nix/install | sh -s -- --daemon
source ~/.nix-profile/etc/profile.d/nix.sh

# Enable flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### Deploy to All VMs
```bash
cd ~/git/cloud/a_solutions/home-manager
./build.sh ship
```

### Deploy to Single VM
```bash
./build.sh ship oci-flex    # Deploy to oci-flex only
```

## Impact on Build Scripts

### Before (Current Issues)
```bash
# build.sh on gcp-proxy FAILS - no jq
get_config() {
    node -e "..." || python3 -c "..."  # Works
}

step_secrets() {
    sops -d secrets.yaml | yq ...  # FAILS - no sops/yq
}
```

### After (Consistent)
```bash
# build.sh works on ALL VMs
get_config() {
    node -e "..." || python3 -c "..."  # Still works
}

step_secrets() {
    sops -d secrets.yaml | yq ...  # NOW WORKS - all VMs have sops/yq
}
```

## Migration Path

1. ✅ Create home-manager configs (DONE)
2. ⏭️ Install Nix on each VM (if not present)
3. ⏭️ Run `./build.sh ship` to deploy
4. ⏭️ Verify tools available: `which sops jq yq`
5. ⏭️ Test build.sh on each VM
6. ⏭️ Remove manual tool installations (optional)

## Notes

- Docker/compose not managed (assumed system packages)
- Age keys need to be set up separately
- Bash configs activate immediately (source ~/.bashrc)
- Tool paths will be in /nix/store or ~/.nix-profile/bin
- System PATH updated automatically by home-manager
