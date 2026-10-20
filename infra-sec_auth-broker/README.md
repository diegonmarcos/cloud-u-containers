# infra-sec_auth-broker (#1066) -- PARKED, not shipped

Identity broker for the multi-SSO sign-in on auth.diegonmarcos.com and account.diegonmarcos.com:
two oauth2-proxy instances (Google, GitHub), email allowlist (`parked/build.json` ->
`auth_broker.allowed_emails`, the ONE place), session cookie `_diego_sso` on `.diegonmarcos.com`.
Runs on oci-apps (headroom), reached by the gcp-proxy hub and the oci-analytics edge over the mesh
(10.0.0.6:4180 google, :4181 github). Caddy side: `infra-sec_caddy/build.json`
`caddy_config.edge_auth.multi_sso` (flag `enabled`, default false).

## Why `parked/`
Ship treats any `<svc>/src/**` or `<svc>/build.json` change as a deploy. The broker has no OAuth
clients yet, so shipping it now would crashloop. Nothing under `parked/` matches that rule.

## Turn it on (owner + one agent)
1. Owner: create the two OAuth clients (steps in backlog ticket #1066), add to sops
   `parked/src/secrets.yaml` (copy `secrets.yaml.example`): AUTH_BROKER_GOOGLE_CLIENT_ID/SECRET,
   AUTH_BROKER_GITHUB_CLIENT_ID/SECRET, AUTH_BROKER_COOKIE_SECRET (32 random bytes, base64url).
2. `git mv infra-sec_auth-broker/parked/build.json infra-sec_auth-broker/build.json` and
   `git mv infra-sec_auth-broker/parked/src infra-sec_auth-broker/src`; link `build.sh` like the other services.
3. Set `edge_auth.multi_sso.enabled` to true in `infra-sec_caddy/build.json`. Ship regenerates both Caddyfiles.
4. Run `infra-sec_caddy/src/test/test-multi-sso.sh` and `9_others/test/edge-auth-probe.sh`.
