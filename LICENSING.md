# Licensing map — cloud-u-containers

> Not legal advice. This is an inventory of what the tree contains and which licence each part
> carries today, written so the owner (and a lawyer, if needed) can decide from facts.

The machine-readable half is [`licenses/`](./licenses):

| File | What it is | Written by |
|---|---|---|
| `licenses/curated.json` | licence of every top-level directory, of every directory carrying a foreign LICENSE that is not an upstream module, of fonts/binaries, and of the container images and flake inputs (read from each upstream's LICENSE file on 2026-10-03, never guessed) | hand |
| `licenses/upstreams.json` | the five vendored upstream trees, with the pin each vendoring recorded | hand |
| `licenses/provenance.json` + `licenses/provenance/<id>.tsv` | upstream-derived vs newly authored, per module and per file | `python3 .github/scripts/licence-provenance.py .` |
| `licenses/inventory.json` | every subject the tree builds from (468), with its licence and where it is declared, plus the rootfs package summary | `python3 .github/scripts/licence-inventory.py refresh .` |

CI: `licence-inventory-guard.yml` runs `licence-inventory.py check .` on every push (no path
filter) and fails, naming it, when something new appears with no entry. Its tester
`.github/scripts/test-licence-inventory-guard.sh` breaks the inventory 17 ways on a fixture repo
(must-fail), makes 5 changes that must stay green (version/tag/digest bumps among them) and runs
6 mutants of the guard that must each turn the suite red.

## 1. Two rules that decide everything below

1. **Third-party code keeps its own licence.** A vendored tree, a pulled image, a Cargo / npm /
   PyPI package: none of it is relicensed by anything in this repository, however much it was
   modified.
2. **This repository has no `LICENSE` file**, so the owner's own code (every service's
   `build.json`, flakes, compose generators, Dockerfiles, own APIs/MCP servers, `_shared/`,
   `_dispatch/`) is under no granted licence today: all rights reserved, readable because the
   repository is public. Recorded as `LicenseRef-NoLicenseGranted`.

## 2. Top-level directories

All 88 top-level directories (each one a service, plus `_shared`, `_dispatch`, `.github`,
`.githooks`, `licenses`) are own code, `LicenseRef-NoLicenseGranted`. What a service *runs* is
mostly a third-party image (section 4), which keeps its own licence; the directory holds the
owner's configuration around it. The exceptions inside them:

| Path | Licence | What it is |
|---|---|---|
| `user-comm_cloud-webmail/src/code/arm64/webapp` | AGPL-3.0-only (with MIT notice from the fork lineage) | Bulwark Webmail 1.9.2 |
| `user-ai_my-ai-api/src/code/vendor/headroom` (+ its `dist/code/arm64` build copy) | Apache-2.0 | Headroom 0.26.0 |
| `user-ai_my-ai_claude-api/src/code/vendor/headroom` | Apache-2.0 | Headroom 0.26.0 (identical copy) |
| `infra-api_google-workspace-mcp/src/code` | MIT | google_workspace_mcp (Taylor Wilsdon) |
| `user-ai_my-ai_claude-api/src/code/claude-config/ponytail` | MIT | ponytail hooks/skills (DietrichGebert) |
| `infra-obs_cloud-spec/dist/assets/site/fonts` and FontAwesome fonts | Apache-2.0 (Open Sans), OFL-1.1 (Source Code Pro, Font Awesome 4.7 fonts) | mdBook theme assets |
| `z_archive/**` | each file's own | archived, outside the inventory (includes the Roundcube calendar plugin and its SabreDAV copy, BSD-style) |

## 3. Upstream-derived vs newly authored (vendored trees)

Measured against the pin each vendoring record names (`licenses/provenance.json`; per file in
`licenses/provenance/<id>.tsv`). Lines are non-blank; "derived" is the multiset overlap with the
upstream counterpart, so "new" is an upper bound on what the owner wrote.

| Module | Upstream @ pin | Licence | Files verbatim / modified / new | % lines upstream-derived |
|---|---|---|---|---|
| cloud-webmail | bulwarkmail/webmail @ `2f1192bb` (1.9.2) | AGPL-3.0-only | 832 / 7 / 2 | 99.8 |
| headroom-my-ai-api | chopratejas/headroom @ `9f7f3adf` (0.26.0) | Apache-2.0 | 576 / 1 / 1 | 100.0 |
| headroom-claude-api | same | Apache-2.0 | 576 / 1 / 1 | 100.0 |
| google-workspace-mcp | taylorwilsdon/google_workspace_mcp, **no pin recorded** | MIT | not measured | — |
| ponytail | **no upstream URL or pin recorded** | MIT | not measured | — |

The webmail changes are owner-authored edits to the composer, identities, mail app, JMAP client
and settings store (+2 new JMAP paging files); the Headroom change is one line in
`headroom/copilot_auth.py` plus `VENDORED.md`. Every modified file stays under its upstream
licence.

## 4. Third-party dependencies (`licenses/inventory.json`)

| Kind | Subjects | Licences |
|---|---|---|
| Container images | 95, of which 43 are the fleet's own `ghcr.io/diegonmarcos/*` builds | own builds: packaging is own code, contents keep their upstream licence. Upstream images: Apache-2.0 (authelia, caddy, etherpad, filebrowser, grist, continuwuity), MIT (crowdsec, gitea, umami, rclone, reveal-md), AGPL-3.0 (vaultwarden, hedgedoc, photoprism, openobserve, mautrix-whatsapp; stalwart and element-web with commercial options), GPL-3.0 (dbgate, maddy, matomo, radicale), GPL-2.0 (mariadb, busybox), BSD (nginx, unbound, valkey, wstunnel), LGPL-2.1 (languagetool), MPL-2.0 (send), ISC (ws4sqlite), PostgreSQL, curl, **BUSL-1.1 (surrealdb)**, Redis (see conflicts), and distribution bases (alpine, debian, ubuntu, kali, distroless, node, python, golang, rust) |
| Cargo crates | 96 | MIT / Apache-2.0 family (91), Unlicense OR MIT (3), BSD-3-Clause, CDLA-Permissive-2.0 |
| npm packages | 91 | MIT (77), Apache-2.0, ISC, BSD, MIT-0, MPL-2.0 OR Apache-2.0, jszip (MIT OR GPL-3.0-or-later) |
| PyPI packages | 78 | Apache-2.0 (33), MIT (28), BSD-3-Clause (9), PSF, MIT-CMU, mixed expressions, **gallery-dl GPL-2.0-only** |
| Flake inputs | nixpkgs | MIT (expressions; each package keeps `meta.license`) |
| Fonts / binaries | 16 | section 2; `infra-sec_caddy/src/pgp-wkd-key.bin` is the owner's public key |

**Rootfs package summary** (`inventory.json::rootfs_packages`, not gated): Dockerfile `RUN` lines
install 70 apt, 14 apk and 4 pip packages into images (e.g. php8.2-*, mariadb-server, nginx,
ffmpeg, imagemagick, nmap/nuclei/testssl in the recon image). Their licences are each
distribution's per-package metadata and are not resolved here.

Transitive dependencies are **not** resolved (needs a cargo / npm / pip / nix resolution the
shared runners do not run for an audit); each package entry says so.

## 5. The owner's own code — licence PROPOSED

**PROPOSED (owner decides, #815):** add a `LICENSE` with the **PolyForm Noncommercial 1.0.0**
licence cloud-infra already carries, so the fleet has one licence for its own code; the
alternative under discussion in #815 is Business Source License 1.1. Either way the vendored
trees, images and packages in sections 2-4 keep their own licences. No licence file was added or
changed by this inventory.

## 6. Conflicts and gaps, with concrete fixes

| # | Finding | Evidence | Fix |
|---|---|---|---|
| 1 | No `LICENSE`: the own code is public but unlicensed | repo root | decide #815, then add `LICENSE` |
| 2 | Bulwark webmail is AGPL-3.0 and **modified** (6 files edited, 2 added), served to network users as webmail.diegonmarcos.com: AGPL §13 requires offering those users the modified source. `VENDOR.md` still says "vendored verbatim (no code edits)" | `licenses/provenance/cloud-webmail.tsv` | add a source link (this repository's path) in the webmail UI / about box; correct `VENDOR.md` |
| 3 | `infra-db_redis` pulls the untagged `redis:alpine`, which floats to Redis 8 (RSALv2 / SSPLv1 / AGPLv3, at the user's choice) while other services pin `redis:7-*` (BSD-3-Clause) | `infra-db_redis/build.json` | pin `redis:7-alpine`, or move to `valkey/valkey` (BSD-3-Clause) as `user-prod_paca` already does |
| 4 | SurrealDB is BUSL-1.1 (kg-store, kg-store-pub): self-hosted use is permitted, offering it as a database service to third parties is not | `docker:surrealdb/surrealdb` | keep kg-store internal / owner-only; record the decision |
| 5 | Own images on GHCR (`*-binaries`, e.g. matrix-element, mautrix-whatsapp, mail-puller) redistribute GPL/AGPL software built by this fleet | `docker:ghcr.io/diegonmarcos/*` entries | keep each image's build recipe public (it is) and add an OCI `org.opencontainers.image.source` / licence label naming the upstream |
| 6 | `user-data_scrappers-api` depends on gallery-dl (GPL-2.0-only); the own service image that bundles it is then a GPL-2.0 combination when distributed | `pypi:gallery-dl` | invoke gallery-dl as a separate program, or accept GPL-2.0 for that image |
| 7 | Vendored trees without a recorded pin: google_workspace_mcp (repo known, revision not), ponytail (neither) | `licenses/upstreams.json` (`measure: false`) | write a `VENDORED.md` with repo + commit beside each, then run the provenance script |
| 8 | Paca images (`pacaai/paca-api`, `-realtime`, `-web`) have no recorded source repository, so no licence could be read | `NOASSERTION` in the inventory | record the source repo in `user-prod_paca/build.json`, then the licence in `curated.json::docker_licences` |
| 9 | Distribution base images and the rootfs packages carry per-package licences that are not itemised | `rootfs_packages` | needed only if images are distributed to third parties: generate an SBOM (e.g. syft) per image then |

## 7. Keeping it true

- A new service directory, dependency, image, flake input, font/binary or LICENSE-carrying
  directory turns `licence-inventory-guard` red until it is recorded: add any curated licence to
  `licenses/curated.json` (images: `docker_licences`), run
  `python3 .github/scripts/licence-inventory.py refresh .` and commit `licenses/inventory.json`.
- When a vendored upstream is bumped, update its pin in `licenses/upstreams.json` (copied from its
  `VENDORED.md` / `VENDOR.md`) and run `python3 .github/scripts/licence-provenance.py .`.
