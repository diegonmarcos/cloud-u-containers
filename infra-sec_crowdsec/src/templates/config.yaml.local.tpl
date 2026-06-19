# CrowdSec config override — deep-merged over the image's default config.yaml
# via CrowdSec's documented *.local mechanism (NOT a full-config replacement,
# so it stays version-stable across upstream image bumps).
#
# Only two things are overridden:
#   1. LAPI listen address — bound to the host interface so Caddy (on gcp-proxy)
#      can reach it over the WireGuard mesh. Inbound is gated by the oci-apps
#      firewall (WG-only) + Authelia 2FA at the Caddy edge.
#   2. Prometheus metrics — enabled on a dedicated host port for the healthcheck.
#
# Online/central API stays disabled (dormant) — see DISABLE_ONLINE_API in compose.
api:
  server:
    listen_uri: @LAPI_LISTEN@
prometheus:
  enabled: true
  listen_addr: @METRICS_ADDR@
  listen_port: @METRICS_PORT@
