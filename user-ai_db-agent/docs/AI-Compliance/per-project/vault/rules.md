# Per-Project Rules: vault/

> `~/git/cloud-vault/` — SSH keys, API tokens, credentials, passwords, 2FA seeds

## Project-Specific BLOCKs

| Pattern | Message |
|---------|---------|
| `git push` vault repo | BLOCKED: Vault contains credentials — verify no plaintext secrets before push |
| `cat\|head\|tail` on `*.json` in `A0_keys/` | BLOCKED: Use `jq` with specific field extraction, never dump full token files |
| Edit `age_keys.txt` | BLOCKED: Age private key — editing this breaks all sops decryption |
| Copy vault files outside repo | BLOCKED: Credentials must not leave the vault directory |

## Project-Specific WARNs

| Pattern | Message |
|---------|---------|
| Read any file in `B0_Passwords/` | WARNING: Accessing password store |
| Read any file in `B1_2fa/` | WARNING: Accessing 2FA seeds |
| Read any file in `C1_Payment/` | WARNING: Accessing payment info |
| `git diff` in vault | WARNING: Diff may expose credentials in terminal output |

## Vault Structure

```
vault/
├── A0_keys/
│   ├── ssh/                  # SSH keys (symlinked to ~/.ssh/)
│   ├── providers/            # API credentials per provider
│   │   ├── authelia/oauth/   # Bearer tokens + get_token.py
│   │   ├── system/oauth/     # age_keys.txt (sops master key)
│   │   └── ...
│   └── api_tokens.json       # Master credentials
├── B0_Passwords/             # Service passwords
├── B1_2fa/                   # TOTP seeds + recovery codes
├── C0_ID/                    # Identity documents
├── C1_Payment/               # Payment card info
└── config, config_mobile     # SSH configs (auto-detected by $HOME)
```

## SSH Config Detection

- Desktop: `vault/config` (detected by `$HOME` = `/home/diego`)
- Mobile: `vault/config_mobile` (detected by `$HOME` contains `termux`)

## Critical Files — Never Expose

- `A0_keys/providers/system/oauth/age_keys.txt` — sops master key
- `A0_keys/api_tokens.json` — all API credentials
- `A0_keys/providers/authelia/oauth/authelia_tokens.json` — bearer tokens
- `B1_2fa/` — TOTP recovery codes
