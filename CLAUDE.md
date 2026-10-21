
## Fleet addressing rule (read before touching any build.json route)

Cloudflare + Hickory are wildcard-only; Caddy is the single SoT for routing and exposure. Every route is WG-only fail-closed (`wgOnly(proxy) = proxy.wg_only ?? true`, off-mesh -> 403) unless the service is on the public allowlist (`_shared/public-route-allowlist.json`, guarded by `_shared/test-public-route-allowlist.mjs`); a container's mesh name is its build.json `dns` (`<name>.app`, Hickory over wg0). Never add per-subdomain Cloudflare records and never set `wg_only:false` to "fix" reachability. Details: cloud-data-my-ai-memory `4___ASSETS___/4.3.Memory/cloud-u-containers/infra-sec_caddy/project_wg-only-fleet-posture.md` and the `feedback_cloudflare_wildcard_only.md` memory entry.
