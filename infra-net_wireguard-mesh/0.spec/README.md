# wireguard-mesh — read-only WG observability panel

> Headscale-shape UI · zero state · zero mutations · declarative inputs only.

## Why this exists

The cloud's VPN topology is already fully declarative (cloud-data-topology.json,
bb-net_vpn/build.json, terraform.json). Humans want a graphical view of that data
without learning the JSON shapes. This service is the view.

## Hard contract

1. **Read-only**: no buttons, no forms, no POST/PUT/DELETE. The HTML/JS bundle
   contains no `fetch` calls. Any future live state goes through a separate
   service (out of scope here).
2. **Frozen snapshot**: the panel renders entirely from a JSON file injected at
   build time as `PORTAL_DATA["mesh"]`. No runtime API.
3. **Declarative inputs**: every node, peer, transport, and route shown comes
   from existing source-of-truth files in the repo. No values are hand-typed
   into the panel — adding a peer to topology data automatically appears here on
   the next deploy. (Fire rule 6: never extend a hardcoded list.)
4. **Authelia-walled**: Caddy enforces 2FA (`proxy.primary.auth: two_factor`)
   in front of every page. Browser-side authn is never reimplemented here.

## Data sources (declarative inputs)

```
                                                   ┌── this service ──┐
cloud-data-topology.json    ──┐                    │                 │
bb-net_vpn/build.json       ──┼─→ derive-mesh-     │ src/data/       │
c_vps/vps_gcloud/...json    ──┤    snapshot.ts ─→  │   mesh.json   ──┼─→ PORTAL_DATA["mesh"]
c_vps/vps_oci/...json       ──┘                    │                 │
                                                   └─────────────────┘
```

The deriver `cloud/9_others/src/engine/derive-mesh-snapshot.ts` flattens the
five inputs into one snapshot:

```jsonc
{
  "_meta": { "generated_at", "schema": "wg-mesh/v1" },
  "nodes": [ { name, role, public_ip, wg_ip, region, os, public_key_fp } ],
  "peers": [ { from, to, allowed_ips, persistent_keepalive } ],
  "transports": [ { name, protocol, port, endpoint, primary, fallback } ],
  "routes":     [ { src_node, dst_subnet, via_transport } ],
  "health":     { tls_expiries, last_snapshot_at }
}
```

Every cross-reference is computed in the deriver, not in the panel. The panel
is dumb: it iterates and renders.

## Sections of the UI

| Section | Reads from | Display |
|---|---|---|
| **Overview** | snapshot._meta + counts | summary cards |
| **Topology** | nodes + peers | hand-rolled SVG: hub + spokes, edges per transport |
| **Nodes** | nodes[] | table with all fields |
| **Peers** | peers[] | per-node groupings |
| **Transports** | transports[] | UDP-direct (primary) vs TCP-tunneled (fallback) |
| **Routes** | routes[] | reachability matrix |
| **Health** | health{} | TLS cert expiries + last snapshot timestamp |

## Deploy

Standard cloud pipeline: `bb-net_wireguard-mesh/build.sh ship` →
`gen-configs` → `ship.yml` → docker pull on oci-apps → live at
https://mesh.diegonmarcos.com (Authelia-walled).

## Memory + footprint

- Container: nginx-alpine + ~200 KB static bundle
- `mem_limit: 32m`, `read_only: true`, no volumes
- Listens on 8080 inside the container; Caddy on gcp-proxy proxies WG-IP-to-host

## Future extensions (not v1)

1. **Live state endpoint**: a separate small service exposes parsed
   `wg show all dump` JSON; the panel optionally polls. Stays read-only.
2. **Per-VM uptime sparkline**: pull from openobserve via the front-api's
   /log + /metric streams once that service exists.
3. **Topology inspect drawer**: clicking a node shows its full peer config
   (still read-only). Already designable in `views/nodes.ts`.
