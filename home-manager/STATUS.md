# Home Manager Deployment Status

## ✅ Completed

1. Created flake.nix with 4 VM configurations
2. Created individual VM configs (gcp-proxy.nix, oci-flex.nix, oci-mail.nix, oci-analytics.nix)
3. Created build.sh using ship pattern
4. Created build.json with VM metadata
5. Generated flake.lock
6. Created comprehensive documentation

## 🔍 VM Status Check

### Nix Installation

| VM | Nix Installed | Version | Type |
|----|---------------|---------|------|
| gcp-proxy | ✅ YES | 2.33.1 | Determinate Nix 3.15.2 |
| oci-flex | ✅ YES | 2.33.2 | Standard Nix |
| oci-mail | ✅ YES | 2.33.1 | Determinate Nix 3.15.2 |
| oci-analytics | ✅ YES | 2.33.1 | Determinate Nix 3.15.2 |

**Result:** ✅ All VMs have Nix installed

### Flakes Support

| VM | Flakes Enabled | Config Location |
|----|----------------|-----------------|
| gcp-proxy | ❌ NO | ~/.config/nix/nix.conf missing |
| oci-flex | ❌ NO | ~/.config/nix/nix.conf missing |
| oci-mail | ❌ NO | ~/.config/nix/nix.conf missing |
| oci-analytics | ❌ NO | ~/.config/nix/nix.conf missing |

**Result:** ❌ Flakes need to be enabled on all VMs

### Current Tools

| Tool | gcp-proxy | oci-flex | oci-mail | oci-analytics |
|------|-----------|----------|----------|---------------|
| sops | ❌ | ❌ | ❌ | ❌ |
| age | ❌ | ❌ | ❌ | ❌ |
| jq | ❌ | ✅ | ✅ | ✅ |
| yq | ❌ | ❌ | ❌ | ❌ |
| docker | ✅ | ✅ | ✅ | ✅ |
| docker-compose | ✅ | ❌ | ✅ | ✅ |
| rsync | ✅ | ✅ | ❌ | ❌ |
| rclone | ❌ | ✅ | ❌ | ❌ |

**Issues:**
- ⚠️ sops/age missing on ALL VMs (needed for secrets decryption)
- ⚠️ jq missing on gcp-proxy (build.sh fallback will use python3)
- ⚠️ yq missing on ALL VMs (needed for YAML→env conversion)
- ⚠️ rsync missing on oci-mail, oci-analytics (deploy will use rclone fallback)

## 🚀 Deployment Plan

### Step 1: Enable Flakes (Required)

Run on EACH VM:
```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Or automated from local machine:
```bash
for vm in gcp-proxy oci-flex oci-mail oci-analytics; do
  ssh "$vm" "mkdir -p ~/.config/nix && echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf"
done
```

### Step 2: Deploy Home Manager

```bash
cd ~/git/cloud/a_solutions/home-manager
./build.sh ship              # Deploy to all VMs
# or
./build.sh ship oci-flex     # Deploy to single VM
```

### Step 3: Verify

On each VM after deployment:
```bash
which sops jq yq rsync rclone  # Should all exist
sops --version
jq --version
```

## ⚡ Performance Considerations

### Build Performance on Free Tier VMs

**gcp-proxy (e2-micro, 1GB RAM, 0.25 vCPU):**
- ⚠️ **VERY SLOW** for builds
- Nix downloads pre-built binaries (usually fast)
- Home manager activation: ~2-5 minutes
- If building from source: can take 30+ minutes
- **Recommendation:** Use binary cache (default enabled)

**oci-analytics (e2-micro, 1GB RAM, 0.25 vCPU):**
- Same as gcp-proxy
- **Recommendation:** Avoid source builds

**oci-flex, oci-mail (Ampere ARM, 24GB RAM, 4 vCPU):**
- ✅ **FAST** - plenty of resources
- Nix builds: 5-15 minutes typical
- Home manager activation: 1-2 minutes

### Why Nix Builds Can Be Slow

1. **Binary Cache Misses:**
   - If package not in cache → builds from source
   - ARM (aarch64) has fewer cached packages
   - Solution: Enable community ARM cache

2. **Low Memory:**
   - e2-micro (1GB) can swap during builds
   - Solution: Use binary cache, avoid large packages

3. **Low CPU:**
   - e2-micro (0.25 vCPU) is throttled
   - Solution: Be patient, or build on local machine

### Our Case (Home Manager)

**Good news:**
- Most packages are pre-built ✅
- We're not building containers (just installing tools) ✅
- Binary cache should have everything ✅
- Estimated time per VM: 2-5 minutes

**Tools to install:**
```
sops, age, jq, yq-go, rsync, rclone, curl, wget,
netcat, htop, btop, ncdu, tree, git, gh, ripgrep,
fd, bat, lsof, iftop, gzip, unzip, zip
```

Most of these are small binaries with pre-built packages.

## 📊 Expected Deployment Time

| VM | RAM | CPU | Architecture | Est. Time | Risk |
|----|-----|-----|--------------|-----------|------|
| gcp-proxy | 1GB | 0.25 | x86_64 | 3-5 min | Low (binary cache) |
| oci-flex | 24GB | 4.0 | aarch64 | 1-2 min | Very Low |
| oci-mail | 24GB | 4.0 | aarch64 | 1-2 min | Very Low |
| oci-analytics | 1GB | 0.25 | x86_64 | 3-5 min | Low (binary cache) |

**Total for all VMs:** ~10-15 minutes

## 🔧 Troubleshooting

### If builds are slow

1. Check binary cache:
```bash
nix show-config | grep substituters
# Should include: https://cache.nixos.org
```

2. Monitor progress:
```bash
# On VM during activation
htop  # Watch CPU/memory
```

3. If stuck/frozen:
- Ctrl+C and retry
- May be downloading large package
- Check: `nix store ping-store` (test cache connection)

### If builds fail (OOM on e2-micro)

Enable extra swap:
```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Or build on local machine and copy:
```bash
# Build locally
cd ~/git/cloud/a_solutions/home-manager
nix build .#homeConfigurations."diego@gcp-proxy".activationPackage

# Copy to VM (not recommended for home-manager)
```

## 🎯 Next Steps

1. ✅ Home manager configs created
2. ⏭️ Enable flakes on all VMs (one command)
3. ⏭️ Run `./build.sh ship` to deploy
4. ⏭️ Verify tools available
5. ⏭️ Test build.sh on containers

## 📝 Notes

- Determinate Nix vs Standard Nix: both support flakes
- ARM VMs may need `nixpkgs.config.allowUnfree = true` for some packages
- Home manager doesn't require root (installs to ~/.nix-profile)
- Existing system packages won't be affected
- Can rollback: `home-manager generations` + `home-manager switch --rollback`
