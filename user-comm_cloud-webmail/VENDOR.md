# Vendored upstream — Cloud Webmail

`Cloud Webmail` is a **full cosmetic rebrand** of the open-source JMAP webmail
client **[root-fr/jmap-webmail](https://github.com/root-fr/jmap-webmail)**
(Next.js 16, native JMAP, built for Stalwart). We clone, rebrand, and build it
as **our own image** in **our own pipeline** — we do NOT use their prebuilt
image and this is NOT a GitHub fork.

| | |
|---|---|
| Upstream | `github.com/root-fr/jmap-webmail` |
| Pinned tag | `v1.7.1` |
| Pinned commit | `d682f5fe238545f34c93947797ad8548ae4d55be` |
| License | MIT (see `src/code/arm64/webapp/LICENSE`) |
| Vendored at | `src/code/arm64/webapp/` |
| Our image | `ghcr.io/diegonmarcos/cloud-webmail-binaries:latest` (Type A) |

## Rebrand applied (cosmetic + naming only — client logic untouched)

- `webapp/package.json` → `name: "cloud-webmail"`, description reworded.
- `webapp/app/layout.tsx` → `metadata.title: "Cloud Webmail"` (+ description).
- UI app name → env `APP_NAME="Cloud Webmail"` (root-fr reads this at request
  time via `/api/config`; the login page, header, etc. all render it).
- Favicon `webapp/app/icon.svg` is a neutral Lucide mail glyph (MIT) — kept
  as the placeholder mark; does not impersonate any brand.
  <!-- ponytail: swap webapp/app/icon.svg for a bespoke Cloud Webmail logo later -->
- Only other upstream-brand strings (`root.cloud`) live in `__tests__/*` fixtures
  (not shipped) and were left as-is.

## Refreshing the vendor

Re-clone upstream at the new tag, re-apply the two edits above, replace
`src/code/arm64/webapp/`, update the commit sha here and in `build.json._doc`,
then re-ship. Pruned from the snapshot (not needed to build): upstream
`Dockerfile`, `docker-compose.yml`, `.dockerignore`, `.gitignore`, and the
`README/ROADMAP/CONTRIBUTING/CHANGELOG` docs. `LICENSE` is kept (MIT).
