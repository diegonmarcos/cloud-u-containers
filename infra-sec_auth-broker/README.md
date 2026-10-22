# infra-sec_auth-broker (#1066)

Identity broker for the multi-SSO sign-in on auth.diegonmarcos.com and account.diegonmarcos.com.
GitHub and Google sign-in by the OAuth **device flow** (RFC 8628): the login page shows a code and
the provider's verification link (github.com/login/device, google.com/device), the broker polls the
provider, checks the provider's user against the allowlist, then sets the session cookie `_diego_sso`
(HMAC signed, `.diegonmarcos.com`, 12h). The shared edge gate accepts that cookie beside the fleet
Bearer and the Authelia session. Authelia is untouched.

One stdlib Python process per provider (`src/code/main.py`), on oci-apps over the mesh
(10.0.0.6:4180 google, :4181 github, :4182 cloudflare, mesh-only bind). Every instance validates the same cookie.
Caddy side: `infra-sec_caddy/build.json` `caddy_config.edge_auth.multi_sso` (flag `enabled`).

## Declarative config (all in `build.json` `auth_broker`)
- Allowlists, the ONE place: `allowed_emails` (Google, verified email) and `allowed_github`
  (login AND numeric id must match). No domain rule exists; the guard rejects one.
- GitHub client id: the public GitHub CLI client id (`providers[github].client_id`). No secret.
- Per-provider flag: `providers[].enabled`. Off = no new sign-ins, the instance still validates sessions.
- Secrets (sops, `src/secrets.yaml`): `AUTH_BROKER_COOKIE_SECRET`, `AUTH_BROKER_GOOGLE_CLIENT_ID/SECRET`.

## Four-provider hub (#1083)
Authelia is the hub. The edge gate accepts, in order: Authelia session, broker cookie `_diego_sso`, Cloudflare Access JWT.
- GitHub web redirect flow: the owner's GitHub OAuth App (`providers[github].web`, client id public, callback
  https://auth.diegonmarcos.com/oauth2/github/callback). Secret = sops key `AUTH_BROKER_GITHUB_APP_CLIENT_SECRET`;
  until it is present the web leg is off and `/oauth2/github/start` serves the device flow (gh public client, also
  at `?flow=device`).
- Cloudflare Access: `<prefix>/cf-auth` verifies `Cf-Access-Jwt-Assertion` (RS256 vs the team certs, iss, aud, exp,
  owner email only) per `auth_broker.cloudflare_access`; the gate branch is `edge_auth.multi_sso.cloudflare_access`.
- Tests: `src/test/test-broker-hub.py`; gate order and forged-header cases in `infra-sec_caddy/src/test/test-multi-sso.sh`.

## Google status
Google rejects the fleet's current client (`invalid_client`: not a "TVs and Limited Input devices"
client), so `providers[google].enabled` is false. Create that client type, update `secrets.yaml`
(and the vault b15-google-oauth), then set the flag true.

## Tests
`src/test/test-broker.py` (device flow against stub providers: code issued, polling, non-owner and
lookalikes rejected, cookie tamper/expiry, open-redirect, rate limit, flags, fail-closed startup).
`infra-sec_caddy/src/test/test-multi-sso.sh` (gate, chooser, allowlist guard, compose policy).

## Cloudflare One sign-in (#1083)

Provider `cloudflare` (`flow: access`, own `enabled` flag, instance :4182, no client id or secret). The chooser button
opens `/oauth2/cloudflare/start?rd=` on auth. / account.; the broker 302s to `login_url`
(https://auth-cf.diegonmarcos.com/oauth2/cloudflare/callback). That hostname is a Cloudflare Access application
(cloud-infra `c_vps/ba-clo_cloudflare`, `terraform.json` `zero_trust.broker_app`: owner-only policy, tunnel
`fleet-edge` ingress straight to this instance). After the Access login Cloudflare forwards the request with
`Cf-Access-Jwt-Assertion`; `/callback` verifies it (RS256 against the team certs, issuer, `cloudflare_access.aud`,
expiry, owner email only), issues the shared `_diego_sso` cookie (domain `.diegonmarcos.com`) and redirects to `rd`
(https under `rd_domain`; a relative `rd` is resolved against the declared chooser host). No valid JWT: 401, no cookie.
Tests: `src/test/test-broker-hub.py` (forged, expired, wrong AUD, non-owner, disabled).
