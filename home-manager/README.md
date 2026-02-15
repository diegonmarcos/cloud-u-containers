# Home Manager Configurations for Cloud VMs

Declarative user environment management using Nix home-manager for all 4 cloud VMs.

## VMs

| VM | User | Arch | RAM | Tools |
|----|------|------|-----|-------|
| gcp-proxy | diego | x86_64 | 1GB | Base + monitoring |
| oci-flex-0 | ubuntu | aarch64 | 16GB | Base (no services yet) |
| oci-flex-1 | ubuntu | aarch64 | 8GB | Base + heavy workloads |
| oci-mail | ubuntu | aarch64 | 24GB | Base + mail tools |
| oci-analytics | ubuntu | x86_64 | 1GB | Base + analytics |

## Tools Installed

All VMs get:
- **Secrets:** sops, age
- **JSON/YAML:** jq, yq
- **Transfer:** rsync, rclone
- **Network:** curl, wget, netcat
- **System:** htop, btop, ncdu, tree
- **Git:** git, gh
- **Text:** ripgrep, fd, bat
- **Monitoring:** lsof, iftop

## Installation

### Prerequisites

Each VM needs Nix installed:

```bash
# On each VM (if not already installed):
curl -L https://nixos.org/nix/install | sh -s -- --daemon
source ~/.nix-profile/etc/profile.d/nix.sh

# Enable flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### Deploy to Single VM

```bash
# From your local machine, deploy to specific VM:
cd ~/git/cloud/a_solutions/home-manager

# Deploy to gcp-proxy
nix run home-manager/release-24.11 -- switch --flake .#diego@gcp-proxy

# Deploy to oci-flex-1
nix run home-manager/release-24.11 -- switch --flake .#ubuntu@oci-flex-1

# Deploy to oci-mail
nix run home-manager/release-24.11 -- switch --flake .#ubuntu@oci-mail

# Deploy to oci-analytics
nix run home-manager/release-24.11 -- switch --flake .#ubuntu@oci-analytics
```

### Deploy to All VMs

Use the deployment script:

```bash
./deploy.sh all          # Deploy to all VMs
./deploy.sh gcp-proxy    # Deploy to specific VM
./deploy.sh oci-flex-0
./deploy.sh oci-flex-1
./deploy.sh oci-mail
./deploy.sh oci-analytics
```

## On Each VM

After deployment, activate the configuration:

```bash
# First time setup on the VM
nix run home-manager/release-24.11 -- init --switch

# Or if home-manager is already bootstrapped
home-manager switch --flake /path/to/home-manager#<user>@<hostname>
```

## Updating

```bash
# Update flake inputs
nix flake update

# Rebuild and switch
./deploy.sh all
```

## Configuration Structure

```
home-manager/
├── flake.nix           # Main flake with all VM configs
├── gcp-proxy.nix       # diego@gcp-proxy config
├── oci-flex-0.nix      # ubuntu@oci-flex-0 config
├── oci-flex-1.nix      # ubuntu@oci-flex-1 config
├── oci-mail.nix        # ubuntu@oci-mail config
├── oci-analytics.nix   # ubuntu@oci-analytics config
├── deploy.sh           # Deployment script
└── README.md           # This file
```

## Features

### Bash Aliases

All VMs get:
- `ll` - ls -lah
- `dps` - docker ps (formatted)
- `dlogs` - docker logs -f
- `dstop` - docker stop
- `drestart` - docker restart
- `dexec` - docker exec -it

### Environment

- Custom colored prompts (shows hostname)
- History settings (10k lines, dedup)
- SOPS_AGE_KEY_FILE auto-detection
- WireGuard mesh IP exports (oci-* VMs)

### Git

- Pre-configured with name/email
- Default branch: main
- Pull strategy: merge (not rebase)

## Troubleshooting

### "nix: command not found"
```bash
source ~/.nix-profile/etc/profile.d/nix.sh
```

### "experimental feature 'flakes' is disabled"
```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### Changes not taking effect
```bash
# Reload bash config
source ~/.bashrc

# Or re-login to the VM
```

## Notes

- Docker/docker-compose are commented out (assumed system-installed)
- Each VM has custom aliases based on its role
- All configs use Nix 24.11 stable channel
- ARM VMs (oci-flex-0, oci-flex-1) use aarch64-linux packages
- x86 VMs (gcp-proxy, oci-analytics) use x86_64-linux packages
