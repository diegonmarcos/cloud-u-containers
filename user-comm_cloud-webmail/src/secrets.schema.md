# cloud-webmail — secrets schema

Bulwark uses **`SESSION_SECRET`** to encrypt stored credentials, the
"remember me" cookie, and settings-sync data. It is wired as a **sops secret**
(not a baked value) through `SESSION_SECRET_FILE=/run/secrets/SESSION_SECRET`
in `src/compose.nix`.

## How the wiring works

When `src/secrets.yaml` exists, the ship engine's
`cloud-ship-container-step-secrets-decrypt.sh` produces in `dist/`:

- `.secrets` — `KEY=VALUE` dotenv (auto-attached as `env_file`)
- `.secrets.d/<KEY>` — one file per key, mode 0600 (mounted at `/run/secrets`)
- `.secrets.json` — `{"KEY": "value"}` (mounted at `/run/secrets.json`)

`_shared/engine.nix` auto-appends `env_file: [".secrets"]` and the two volume
mounts to every service. `compose.nix` sets `SESSION_SECRET_FILE` to the mounted
per-key file path, so Bulwark reads the secret from disk (the `_FILE` /
daemon-native pattern) rather than from a baked env value.

| Key | Where used | What it is |
|-----|-----------|------------|
| `SESSION_SECRET` | Bulwark credential/settings encryption + "remember me" + settings sync | `openssl rand -base64 32`. Read via `SESSION_SECRET_FILE=/run/secrets/SESSION_SECRET`. Absent → settings-sync/remember-me disabled; login/JMAP still work. |

## Adding the secret (parent does this before shipping)

```bash
cd ~/git/cloud-infra/a_solutions/user-comm_cloud-webmail/src
# create + encrypt (age recipients per repo .sops.yaml)
sops secrets.yaml        # add:  SESSION_SECRET: <openssl rand -base64 32>
cd ..
./build.sh ship
```

There is intentionally **no `src/secrets.yaml` in this commit** (it must be
sops/age-encrypted; this change does not hold the key).

## OIDC (follow-up)

To upgrade from Stalwart password auth to Authelia SSO, see
`build.json._doc._oidc_followup`: register a public PKCE client in
`a_solutions/infra-sec_authelia/src/oidc-clients.json`, then set
`OAUTH_ENABLED=true`, `OAUTH_CLIENT_ID=cloud-webmail`,
`OAUTH_ISSUER_URL=https://auth.diegonmarcos.com`. Blocked on Stalwart⇄Authelia
OIDC token federation, hence not enabled in v1.
