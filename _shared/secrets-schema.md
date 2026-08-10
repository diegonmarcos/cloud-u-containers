# `secrets.yaml` schema — the `_credentials` convention

Every service `secrets.yaml` MUST contain a top-level `_credentials` block alongside the app-consumed keys. The block documents every secret as a human-readable credential record (URL, username, plaintext, hash, notes), so a password rotation never loses the ability to log back in.

## Rules

1. **Top-level keys** (no `_` prefix) are the values the app consumes. Decrypted into `dist/.secrets` and shipped to the container as env vars / mounts.
2. **Top-level keys starting with `_`** (e.g. `_credentials`, `_meta`) are metadata. Engines **strip** them before `.secrets` reaches a VM; they stay only in sops.
3. Every app-consumed key should be **referenced** (by value) from at least one field inside some `_credentials.<name>` entry. Lint enforces this.

## Block shape

```yaml
SERVICE_ADMIN_PASSWORD: '$2y$10$/NAb…'        # app-consumed (bcrypt hash)
SERVICE_SMTP_PASSWORD: 'smtppass'             # app-consumed
_credentials:
  admin:
    type: password                            # password|token|oauth|db|ssh|apikey|webhook
    url: https://webmail.example.com/?admin
    username: admin
    password: <plaintext>                     # what YOU type to log in
    hashed: '$2y$10$/NAb…'                    # mirror of top-level hash if any
    note: "pairs with SERVICE_ADMIN_PASSWORD"
  smtp:
    type: password
    url: smtps://mail.example.com:465
    username: noreply@example.com
    password: smtppass
```

## Credential types

| type       | typical fields                                                    |
|------------|-------------------------------------------------------------------|
| `password` | url, username, password, hashed?, totp_secret?, recovery_codes?   |
| `token`    | url?, token                                                       |
| `apikey`   | url?, token                                                       |
| `oauth`    | url?, client_id, client_secret                                    |
| `db`       | url?, username, password, database?, host?                        |
| `ssh`      | url?, username, value (key material)                              |
| `webhook`  | url, token?                                                       |

## Engines

| Engine | Behaviour |
|---|---|
| `1_configs/.../cloud-ship-container-step-secrets-decrypt.sh` | Filters `_`-prefix keys — `.secrets` on the VM only contains the app-consumed keys |
| `1_configs/.../cloud-ship-nix-homemanager-step-secrets-decrypt.sh` | Same filter |
| `a_solutions/aa-sui_mail-mcp/src/run.sh` | Inline `sops → jq filter _-prefix → eval` at boot |
| `2_secrets/src/engine/secrets.sh` | Human-facing viewer — shows everything, nested keys flattened as dotted paths |

## Verification

```sh
~/git/cloud/1_configs/src/deploy/scripts/audit-credentials-coverage.sh
~/git/cloud/1_configs/tests/test-secrets-roundtrip.sh
```
