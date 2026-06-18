{
  # Upstreams use raw WG IPs (not DNS) — Caddy is the *.app target
  @DEBUG_LINE@
  admin @ADMIN_BIND@
  order @ORDER@
  auto_https @AUTO_HTTPS@
  # ACME via DNS-01 (Cloudflare) — eliminates port-80 HTTP-01 dependency
  # and supports wildcard certs for *.diegonmarcos.com. Token sourced
  # from .secrets (env_file in compose.nix). Phase 2a of public-surface
  # collapse plan (0_tasks/TASK-net-20260508-01_collapse-public-to-443.md).
  acme_dns cloudflare {env.CF_API_TOKEN}
  # caddy-l4 owns :443 (Phase 3): https_port 8443 keeps Caddy HTTPS off
  # the public socket so caddy-l4 SNI mux + fall-through can run.
  https_port 8443
  # Disable HTTP/3 / QUIC — UDP/443 is reserved for WireGuard fallback
  # (firewall.nix on hub redirects udp/443 → udp/51820 for peers behind
  # networks that block 51820/udp). Phase 4 of collapse plan.
  servers {
    protocols h1 h2
    # PROXY protocol unwrap for the local caddy-l4 → :8443 hop. caddy-l4
    # owns :443 and pipes TLS to 127.0.0.1:8443 with `proxy_protocol v2`
    # prepended (caddyfile.nix @notmail fall-through). Without this wrapper
    # the HTTP layer saw remote_ip=127.0.0.1 for EVERY request, so the
    # wg-only tier gate (`@not_wg not remote_ip 10.0.0.0/24`) returned
    # Forbidden to legitimate WG clients (vault.diegonmarcos.com regression,
    # 2026-06-12). Order matters: proxy_protocol BEFORE tls — the PP header
    # arrives ahead of the TLS ClientHello. `allow 127.0.0.1/32` restricts
    # PP trust to the local hop; anything else cannot spoof a client IP.
    listener_wrappers {
      proxy_protocol {
        allow 127.0.0.1/32
      }
      tls
    }
  }
  on_demand_tls {
    ask @ODT_ASK_URL@
  }
@L4_SECTION@
}
