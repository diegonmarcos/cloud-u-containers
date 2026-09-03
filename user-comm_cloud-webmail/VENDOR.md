# Vendored upstream — Cloud Webmail

`Cloud Webmail` is **[Bulwark](https://github.com/bulwarkmail/webmail)** — a
Stalwart-native JMAP webmail (Next.js 16 + React 19) with true
multi-account / multi-server support. We clone the pinned upstream tag and
build it as **our own image** in **our own pipeline** — we do NOT use their
prebuilt ghcr image and this is NOT a GitHub fork.

| | |
|---|---|
| Upstream | `github.com/bulwarkmail/webmail` |
| Pinned tag | `1.9.2` |
| Pinned commit | `2f1192bb3285dea2c8b8ece461d52967fe0e6706` |
| License | AGPL-3.0-only (see `src/code/arm64/webapp/LICENSE` + `NOTICE`) |
| Vendored at | `src/code/arm64/webapp/` |
| Our image | `ghcr.io/diegonmarcos/cloud-webmail-binaries:latest` (Type A) |

## Branding / config (env only — source unmodified)

The upstream source is vendored **verbatim** (no code edits). All naming and
behaviour are set at runtime through env in `src/compose.nix`, which Bulwark
reads (see `webapp/.env.example`):

- `APP_NAME="Cloud Webmail"`, `APP_SHORT_NAME`, `APP_DESCRIPTION`
- `JMAP_SERVER_URL=https://jmap.diegonmarcos.com` (default Stalwart server)
- `ALLOW_CUSTOM_JMAP_ENDPOINT=true` (multi-account/multi-server login field)
- `STALWART_FEATURES=true` (password change + Sieve filters)
- `SESSION_SECRET_FILE=/run/secrets/SESSION_SECRET` (sops secret — see
  `src/secrets.schema.md`)

## Multi-account / multi-server

Bulwark is multi-account-native. `ALLOW_CUSTOM_JMAP_ENDPOINT=true` adds a "JMAP
Server" field to the login form so users can connect to any JMAP server beyond
the default `JMAP_SERVER_URL` (`.env.example`: "Allow users to specify a custom
JMAP server URL on the login form … Users can connect to any JMAP-compatible
server"). External servers must include this origin in their CORS
`Access-Control-Allow-Origin`. For a curated list, `JMAP_SERVERS` (JSON array)
is the alternative, configurable from the admin dashboard.

## Refreshing the vendor

Anonymous clone at the new tag, replace `src/code/arm64/webapp/` wholesale,
update the tag + commit here and in `build.json._doc.upstream` + the Dockerfile
comment/`ARG GIT_COMMIT`/label, then re-ship:

```bash
git -c http.extraheader= clone https://github.com/bulwarkmail/webmail.git
cd webmail && git checkout <tag>
```

Pruned from the snapshot (not needed to build): upstream `Dockerfile`,
`docker-compose.yml`, `.dockerignore`, `.gitignore`, `.github/`, `.husky/`,
`e2e/`, `integration/`, `screenshots/`, playwright/vitest configs, `setup.sh`,
`.env.dev.example`, and `README/CHANGELOG/CONTRIBUTING/FEATURES` docs. **Kept**
`LICENSE` + `NOTICE` (AGPL-3.0 + MIT fork-lineage attribution — required),
`.env.example`, `VERSION` (read by `next.config.ts`), and all build sources.

## Build notes (Bulwark / Next 16)

- `output: "standalone"` (confirmed in `webapp/next.config.ts`).
- Bulwark's `package.json` build script uses `--turbopack`, but its own
  Dockerfile pins **`npx next build --webpack`** for the production image — our
  Dockerfile matches (`--webpack`).
- `.git` is not vendored, so `next.config.ts`'s `git rev-parse` fallback can't
  run; the Dockerfile passes `ARG GIT_COMMIT=2f1192b` for the About screen.
- Runner stage creates `/app/data/{settings,admin,admin-state,telemetry}` owned
  by the `nextjs` user (matching upstream) so settings-sync/admin writes work
  without a mounted volume.
