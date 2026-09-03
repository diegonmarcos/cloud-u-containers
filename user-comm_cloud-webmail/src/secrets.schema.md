# cloud-webmail — secrets schema (FOLLOW-UP, not yet wired)

Cloud Webmail **ships without any sops secrets** — it is fully functional with
password auth against Stalwart JMAP and non-secret runtime env set inline in
`compose.nix`.

The single optional secret below is a **follow-up** the parent can add. There
is intentionally **no `src/secrets.yaml` yet** (it must be sops/age-encrypted;
this agent does not hold the key). When one is added, the engine auto-appends
`env_file: [".secrets"]` and mounts `.secrets.d` / `.secrets.json` — no
`compose.nix` change needed.

| Key            | Where used                     | What it is |
|----------------|--------------------------------|------------|
| `SESSION_SECRET` | root-fr "remember me" cookie signing | `openssl rand -base64 32`. OPTIONAL — absence only disables the "remember me" checkbox; login/JMAP works without it. |

## OIDC (further follow-up)

To upgrade from Stalwart password auth to Authelia SSO, see
`build.json._doc._oidc_followup`: register a public PKCE client in
`a_solutions/infra-sec_authelia/src/oidc-clients.json`, then set
`OAUTH_ENABLED=true`, `OAUTH_CLIENT_ID=cloud-webmail`,
`OAUTH_ISSUER_URL=https://auth.diegonmarcos.com`. Blocked on Stalwart⇄Authelia
OIDC token federation, hence not enabled in v1.

## Adding the secret

```bash
cd ~/git/cloud-infra/a_solutions/user-comm_cloud-webmail/src
# create + encrypt (age recipients per repo .sops.yaml)
sops secrets.yaml        # add: SESSION_SECRET: <openssl rand -base64 32>
cd ..
./build.sh ship
```
