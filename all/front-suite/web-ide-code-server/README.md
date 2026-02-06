# Web IDE (Code-Server)

VS Code running in the browser via [code-server](https://github.com/coder/code-server).

## Quick Start

```bash
# 1. Ensure age key is in place
cp /path/to/vault/A0_keys/age/keys.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# 2. Get your age public key
age-keygen -y ~/.config/sops/age/keys.txt
# Copy the output (age1xxx...)

# 3. Update .sops.yaml with your public key

# 4. Edit secrets.yaml with real passwords, then encrypt
sops -e -i secrets.yaml

# 5. Start (decrypts secrets automatically)
./start.sh
```

## Secrets Management (sops + age)

Secrets are encrypted with [sops](https://github.com/getsops/sops) using [age](https://github.com/FiloSottile/age).

| File | Description |
|------|-------------|
| `secrets.yaml` | Encrypted secrets (safe to commit) |
| `.sops.yaml` | sops configuration with age public key |
| `start.sh` | Decrypts secrets and starts container |
| `.env` | Decrypted secrets (gitignored, generated) |

### Edit Secrets

```bash
# Decrypt in editor, re-encrypts on save
sops secrets.yaml
```

### Manual Decrypt

```bash
sops -d secrets.yaml
```

## Configuration

| Variable | Description |
|----------|-------------|
| `code_server_password` | Web login password |
| `sudo_password` | Sudo password in container |

## Ports

| Port | Service |
|------|---------|
| 8443 | Code-Server Web UI |

## Volumes

| Path | Description |
|------|-------------|
| `./config` | Code-server config & extensions |
| `./workspace` | Default workspace directory |

## Behind Reverse Proxy (NPM)

To expose via NPM:

1. Add proxy host for `ide.diegonmarcos.com`
2. Forward to `code-server:8443`
3. Enable WebSocket support
4. Add Authelia protection if needed

## Extensions

Extensions are persisted in `./config/extensions`. Install via:
- UI: Extensions sidebar
- CLI: `code-server --install-extension <extension-id>`
