# Status page — schema + front project plan (§4C)

Two pieces: (1) `status.json` schema written by the reports engine, (2) a minimal
front project that renders it via the `PORTAL_DATA` pattern. Both data-driven.

## 1. `status.json` schema (the contract)

Written by the Phase-1 tiered-reports engine after each T1/T2 run to
`build-notify.json#status_page.output_path` (`/opt/health/status.json`), served
statically from the Caddy edge. The broker/digest READ it; they do not write it.

Canonical example + schema (states: `green|yellow|red|unknown|stale`):

```json
{
  "schema_version": 1,
  "generated_at": 1720000000,
  "max_age_secs": 300,
  "overall": "green",
  "services": [
    {
      "name": "maddy",
      "vm": "oci-mail",
      "category": "endpoints",
      "state": "green",
      "since": 1719990000,
      "detail": "IMAPS 200, SMTPS ok",
      "url": "https://mail.diegonmarcos.com",
      "last_incident": null
    }
  ],
  "vms": [
    { "name": "oci-mail", "state": "green", "wg_handshake_age_secs": 12, "psi_mem": 4, "disk_pct": 61 }
  ],
  "counts": { "green": 40, "yellow": 1, "red": 0, "unknown": 0, "stale": 0 }
}
```

Field rules:
- `state` per service is the reports engine's classification. `stale` is set by
  the renderer when `now - generated_at > max_age_secs` (kills the false-RED
  from R1 — a stale page shows STALE, not RED).
- `overall` = worst-of service states (red > stale > yellow/unknown > green).
- `since` = epoch when the current state began (for "down for 3h" display).

The **history JSONL** the digest reads (`build-notify.json#digest.reports_history_jsonl`,
`/opt/health/history/reports.jsonl`) is the append-only per-run log; one line per
service per run: `{"ts","service","state","tier","detail"}`. `status.json` is the
latest snapshot; the JSONL is the trend source. Both are engine-owned outputs.

## 2. Front project — `front/c-Cloud/status`

Minimal static page (Sass+esbuild archetype, matches `c-Cloud/api`). No fetch():
consume `globalThis.PORTAL_DATA["status"]` from a generated
`dist/data-status.json.js` wrapper (same generator as the other cloud pages).

```
front/c-Cloud/status/
├── build.sh            → ../../_engine.sh symlink (repo convention)
├── build.json          { name:"status", archetype:"sass-esbuild", port:8023 }
├── public/index.html   Matomo head snippet + <main id="status">
├── src/
│   ├── data/
│   │   └── status.json.js   thin bootstrap; real data injected at deploy from
│   │                        the edge /status/status.json (copied into dist by CI)
│   ├── scss/_status.scss    .status-card{} .state-green/.state-yellow/.state-red
│   │                        (NO inline CSS — SCSS classes only, per D.3)
│   └── typescript/status.ts render PORTAL_DATA["status"].services into cards,
│                            color by state, "updated Ns ago", STALE banner if
│                            generated_at older than max_age_secs.
```

Behaviour:
- Read `PORTAL_DATA["status"]` (populated at page load from the edge-served
  `status.json` via the `data-status.json.js` wrapper — CORS-safe, `file://`-safe).
- Group cards by category; badge each by `state`; header shows `overall` + age.
- If `now - generated_at > max_age_secs`: show a STALE banner (do not paint green).
- Dev port 8023 (next free in the 8000-8022 block → 8023). Deploy to
  `status.diegonmarcos.com` (or `/status` on the edge) — wildcard DNS already
  resolves it; add a Caddy route in `infra-sec_caddy` build.json `proxy.primary`
  pointing at the static file server for `status.json` + the page.

Scaffolding the full project is a front-repo task (its own `build.sh`/`build.json`/
SCSS pipeline conventions). This plan is the complete spec; the front agent
creates the files. The **data contract** (`status.json` above) is frozen here so
the reports engine and the page agree.
