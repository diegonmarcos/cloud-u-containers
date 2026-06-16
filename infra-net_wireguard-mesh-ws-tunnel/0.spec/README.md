# wireguard-mesh-ws-tunnel — WireGuard-over-TCP/443 fallback

> Sibling of `bb-net_wireguard-mesh` (the read-only observability panel).
> Two folders, two containers, one architectural unit.

## Why this exists

WireGuard runs on UDP/51820. Most networks allow that; some don't (airport,
hotel, conference, corporate guest, captive portals). This service adds a
TCP/443 fallback path: clients on hostile networks tunnel WG packets inside
TLS-on-TCP-443 (looks like normal HTTPS) instead of raw UDP.

UDP/51820 stays primary — fastest, lowest latency. wstunnel only kicks in
when the client's network blocks UDP.

## Architecture

```
                           ┌─ Diego on hotel Wi-Fi ─┐
                           │  wstunnel-client       │
                           │  listens UDP/127.0.0.1:51821
                           │  → WSS to vpn.diegonmarcos.com:443
                           └────────────┬───────────┘
                                        │ TLS over TCP/443
                                        ▼
                                 [Cloudflare DNS]
                                        │
                                        ▼
                                  [gcp-proxy:443]
                                        │ Caddy SNI route
                                        ▼
                            wstunnel-server container
                            (this folder, network_mode: host)
                                        │ UDP loopback
                                        ▼
                            kernel WireGuard listener
                            (already there, untouched, 0.0.0.0:51820)
```

## Sibling cross-references

| Consumer | Reads from this build.json |
|---|---|
| `bb-net_wireguard-mesh` (panel) | `transports.{wg0,wg0-tcp}` for the snapshot deriver |
| `unix/.../wireguard-wstunnel.nix` (laptop) | `transports.wg0-tcp.endpoint_template` + the `WSTUNNEL_PATH_PREFIX` secret |
| Caddy deriver | `proxy.primary` block (domain, websocket, upstream) |

This folder is the **single source of truth** for VPN transport metadata.
Adding a new transport (e.g., a future Tailscale relay) lands here, and every
consumer picks it up declaratively.

## Memory + footprint

- Container: upstream `ghcr.io/erebe/wstunnel:latest`, ~10 MB image
- `mem_limit: 64m`, `read_only: true`, `network_mode: host`
- Listens on TCP/127.0.0.1:8080 inside host net-ns; Caddy reverse-proxies
  `vpn.diegonmarcos.com` → 127.0.0.1:8080 with WS upgrade
- Forwards UDP packets to host's 127.0.0.1:51820 (kernel WG)

## Security posture

1. `--restrict-to 127.0.0.1:51820` — wstunnel-server can ONLY forward to the
   WG kernel listener. It cannot be coerced into being a generic SOCKS proxy.
2. `--http-upgrade-path-prefix ${WSTUNNEL_PATH_PREFIX}` — random 32-char hex
   secret in the WS upgrade URL path. Caddy returns 404 for any other path,
   so internet scanners hitting `vpn.diegonmarcos.com/` see only "404 Not
   Found" and never reach the wstunnel binary.
3. Cert: standard Let's Encrypt via Caddy at the gcp-proxy ingress.
4. No new public ports — reuses the existing TCP/443 listener.

## Deploy + tester flow

```bash
# Initial: rotate WSTUNNEL_PATH_PREFIX
openssl rand -hex 32   # → paste into secrets.yaml, then sops -e

# Deploy
./build.sh ship    # invokes the universal cloud-ship-container-engine

# Tester
0.spec/test.sh
```

## Decommission

When/if you migrate to Tailscale + Headscale, this folder + the route
`vpn.diegonmarcos.com` get deleted in one commit. The panel's snapshot
deriver gracefully falls back to "wg0 only" when this build.json is absent
(see `derive-mesh-snapshot.ts`).
