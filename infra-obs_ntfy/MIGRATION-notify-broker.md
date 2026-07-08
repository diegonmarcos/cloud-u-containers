# MIGRATION — producers → notify-broker event contract

> Status: contract frozen for the parallel vm-pilot task. This file DEFINES the
> interface; it does NOT edit vm-pilot. The vm-pilot agent owns
> `cloud/b_infra/_shared/vm-pilot/{agents,protection}/*.nix` and switches those
> producers from raw ntfy POSTs to broker events per this spec.

## Why

Today every agent posts **raw** to the `health_resources` firehose:

```
journal-ntfy.nix       → curl -d "..." http://10.0.0.6:8090/health_resources
load-shedder.nix       → (P1) only syslog + /run/load-shedder.fired, NO ntfy
watchdog-petter.sh      → ntfy() helper → health_resources
```

That loses severity, dedups nothing, never escalates, and floods one topic.

The broker (`infra-obs_ntfy/src/code/notify-broker.py`, HTTP on `:8092`) applies
the data-driven policy in `build-notify.json` (severity map, routing table,
dedup, flap, escalation, recovery) and fans out to the right ntfy topic + Matrix
+ email. Producers stop deciding routing; they just emit **facts**.

## The event contract

`POST http://<ntfy-host>:8092/event`  (WG-direct, e.g. `http://10.0.0.6:8092`)
Content-Type: `application/json`

```json
{
  "source":    "load-shedder",          // producer id (free text, for provenance)
  "class":     "load_shed",             // event class → severity_map.by_class in policy
  "severity":  "crit",                  // OPTIONAL explicit level (info|warn|crit|page); wins over class
  "key":       "oci-mail:load_shed",    // REQUIRED identity for dedup / escalation / recovery pairing
  "category":  "resources",             // OPTIONAL; else resolved from `unit`, else "default"
  "unit":      "load-shedder",          // OPTIONAL systemd unit → category_by_unit glob table
  "title":     "Load shed on oci-mail",
  "body":      "PSI mem avg10=72, stopped 3 non-tier1 containers",
  "host":      "oci-mail",
  "service":   "maddy",                 // OPTIONAL affected service
  "recovered": false,                   // true = condition cleared → paired [RESOLVED] notice, key reset
  "ack":       false                    // true (or POST /ack) = ack the key, reset escalation ladder
}
```

Only `key` + one of (`class` | `severity`) + `title` are strictly required.

### Ack path

`POST http://<host>:8092/ack` with `{"key": "oci-mail:load_shed"}` (or an ntfy
action button wired to that URL) resets the escalation ladder for that key.

## Class → severity (data-driven, see build-notify.json#severity_map.by_class)

| class | severity | emitted by |
|-------|----------|-----------|
| `heartbeat_miss`, `mesh_peer_down`, `island_down`, `load_shed_tier1`, `deploy_failed` | **page** | health-agent (T0), load-shedder, activation guard |
| `fd_exhaustion`, `load_shed`, `container_down`, `endpoint_down`, `cert_expired`, `disk_full`, `oom_kill` | **crit** | resource-bouncer, load-shedder, reports |
| `psi_high`, `disk_warn`, `cert_expiring`, `backup_stale`, `flapping` | **warn** | health-agent, reports |
| `deploy_ok`, `heartbeat_ok`, `recovered` | **info** | (recovery / heartbeat) |

Add a class = edit `2_configs/src/inputs/notify-policy.json#severity_map.by_class`
and re-run `bash 2_configs/build.sh all`. Never hardcode severity in the producer.

## What each vm-pilot producer should emit (guidance only)

- **`protection/load-shedder.nix`** (plan P1/P5):
  - on shed (non-tier1): `{class:"load_shed", key:"<host>:load_shed", host, title, body:"PSI=.. stopped N"}`
  - on tier1 shed (last resort): `{class:"load_shed_tier1", key:"<host>:load_shed_tier1", ...}`
  - on recovery/auto-restore: same `key`, `{recovered:true}`
  - on deploy-failed marker (`/run/load-shedder.deploy-failed`): `{class:"deploy_failed", key:"<host>:load-shedder-deploy", ...}` (P5)

- **`agents/health-agent.nix`** (plan P2/P3, T0 heartbeat):
  - fd pressure: `{class:"fd_exhaustion", key:"<host>:fd", body:"file-nr 71% of file-max"}` at 70/90%
  - WG handshake stale / peer unreachable: `{class:"mesh_peer_down", key:"<host>:wg:<peer>", ...}`
  - T0 heartbeat OK: `{class:"heartbeat_ok", key:"<host>:heartbeat", recovered:true}`; miss: `{class:"heartbeat_miss", ...}`

- **`dotfiles/.../journal-ntfy.sh`** (retire the firehose):
  - keep its `route()` unit→category resolution, but instead of `POST /<topic>`,
    emit `{source:"journald", unit:"<unit>", class:"<mapped>", key:"<host>:<unit>:<msghash>", title, body, host}`.
    The broker resolves category from `unit` via `category_by_unit` and routes.

## Backward-compatible rollout

The broker is additive. Until vm-pilot switches over, producers keep posting raw
to topics and nothing breaks. As each `.nix` producer is migrated (own task), it
points at `:8092/event`. The broker's `category_by_unit` table mirrors
journal-ntfy's existing `route()` so behaviour is preserved, plus severity/dedup/
escalation on top.

## Deployment note

Broker + digest run as sidecars in the ntfy compose stack (add to
`infra-obs_ntfy/build.json#containers` + `compose.nix` when wiring the runtime —
mount `./code/notify-broker.py`, `./code/notify-digest.py`, and the
`build-notify.json` symlink at `/app/build-notify.json`; env from the sops
`.secrets`). That container wiring is intentionally left for the runtime-wiring
step; the logic + policy + tests are complete and validated here.
