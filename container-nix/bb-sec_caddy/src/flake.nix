{
  description = "Caddy - Declarative reverse proxy with automatic HTTPS (replaces NPM on gcp-proxy + oci-mail)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "caddy";
      http_port = 80;
      https_port = 443;
      admin_port = 2019;
    };

    # WireGuard IPs
    gcp = "10.0.0.1";       # gcp-proxy
    flex = "10.0.0.2";      # oci-flex (on-demand)
    mail = "10.0.0.3";      # oci-mail
    analytics = "10.0.0.4"; # oci-analytics

    # ── Dashboard data ───────────────────────────────────────────

    vms = {
      "gcp-proxy" = {
        alias = "gcp-proxy";
        provider = "GCP";
        tier = "Free";
        ip = "35.226.147.64";
        wg = gcp;
        ram = "1 GB";
        cpu = "e2-micro (0.25 vCPU)";
        arch = "x86_64";
        availability = "24/7";
      };
      "oci-flex" = {
        alias = "oci-flex";
        provider = "OCI";
        tier = "Paid";
        ip = "144.24.196.72";
        wg = flex;
        ram = "8 GB";
        cpu = "Ampere A1 (2 OCPU)";
        arch = "aarch64";
        availability = "Wake-on-demand";
      };
      "oci-mail" = {
        alias = "oci-mail";
        provider = "OCI";
        tier = "Free";
        ip = "130.110.251.193";
        wg = mail;
        ram = "1 GB";
        cpu = "E2.1.Micro";
        arch = "x86_64";
        availability = "24/7";
      };
      "oci-analytics" = {
        alias = "oci-analytics";
        provider = "OCI";
        tier = "Free";
        ip = "129.151.228.66";
        wg = analytics;
        ram = "1 GB";
        cpu = "E2.1.Micro";
        arch = "x86_64";
        availability = "24/7";
      };
    };

    services = [
      { domain = "proxy.diegonmarcos.com";              name = "Dashboard";       vm = "gcp-proxy";     port = "—";   auth = "Authelia + Bearer"; avail = "24/7"; }
      { domain = "auth.diegonmarcos.com";                name = "Authelia 2FA";    vm = "gcp-proxy";     port = "9091"; auth = "Public (bypass)";   avail = "24/7"; }
      { domain = "api.diegonmarcos.com";                 name = "API (Flask+Rust)";vm = "gcp-proxy";     port = "5000/8080"; auth = "Flask: Authelia + Bearer / Rust: Public"; avail = "24/7"; }
      { domain = "vault.diegonmarcos.com";               name = "Vaultwarden";     vm = "gcp-proxy";     port = "80";  auth = "Authelia + Bearer"; avail = "24/7"; }
      { domain = "rss.diegonmarcos.com";                 name = "ntfy Push";       vm = "gcp-proxy";     port = "8090"; auth = "Authelia + Bearer"; avail = "24/7"; }
      { domain = "mail.diegonmarcos.com";                name = "Mailu";           vm = "oci-mail";      port = "8444"; auth = "Authelia + Bearer"; avail = "24/7"; }
      { domain = "sync.diegonmarcos.com";                name = "Syncthing";       vm = "oci-mail";      port = "8384"; auth = "Authelia + Bearer"; avail = "24/7"; }
      { domain = "cal.diegonmarcos.com";                 name = "Radicale";        vm = "oci-mail";      port = "5232"; auth = "Public";            avail = "24/7"; }
      { domain = "analytics.diegonmarcos.com";           name = "Matomo";          vm = "oci-analytics"; port = "8080"; auth = "Hybrid (public tracking)"; avail = "24/7"; }
      { domain = "photos.diegonmarcos.com";              name = "PhotoPrism";      vm = "oci-flex";      port = "3013"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "db.diegonmarcos.com";                  name = "NocoDB";          vm = "oci-flex";      port = "8085"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "ide.diegonmarcos.com";                 name = "Code Server";     vm = "oci-flex";      port = "8443"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "drive-notes-affine.diegonmarcos.com";  name = "AFFiNE";          vm = "oci-flex";      port = "3010"; auth = "Public";            avail = "Wake"; }
      { domain = "sheets.diegonmarcos.com";              name = "Grist";           vm = "oci-flex";      port = "3011"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "diegonmarcos.com";                     name = "Landing Page";    vm = "GitHub Pages";  port = "—";   auth = "Public";            avail = "24/7"; }
      { domain = "linktree.diegonmarcos.com";            name = "Linktree";        vm = "GitHub Pages";  port = "—";   auth = "Public";            avail = "24/7"; }
      { domain = "cloud.diegonmarcos.com";               name = "Cloud Dashboard"; vm = "GitHub Pages";  port = "—";   auth = "Public";            avail = "24/7"; }
      { domain = "nexus.diegonmarcos.com";               name = "Nexus";           vm = "GitHub Pages";  port = "—";   auth = "Public";            avail = "24/7"; }
      { domain = "suite.diegonmarcos.com";               name = "Suite Apps";      vm = "GitHub Pages";  port = "—";   auth = "Public";            avail = "24/7"; }
      { domain = "maps.diegonmarcos.com";                name = "Maps";            vm = "GitHub Pages";  port = "—";   auth = "Public";            avail = "24/7"; }
      { domain = "app.diegonmarcos.com/windmill/";        name = "Windmill";        vm = "oci-analytics"; port = "8000"; auth = "Authelia + Bearer"; avail = "24/7"; }
      { domain = "app.diegonmarcos.com/etherpad/";        name = "Etherpad";        vm = "oci-flex";      port = "3012"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "app.diegonmarcos.com/filebrowser/";     name = "FileBrowser";     vm = "oci-flex";      port = "3015"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "app.diegonmarcos.com/hedgedoc/";        name = "HedgeDoc";        vm = "oci-flex";      port = "3010"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "app.diegonmarcos.com/revealmd/";        name = "Reveal.md";       vm = "oci-flex";      port = "3014"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "app.diegonmarcos.com/dozzle/";          name = "Dozzle";          vm = "gcp-proxy";     port = "9999"; auth = "Authelia + Bearer"; avail = "24/7"; }
      { domain = "app.diegonmarcos.com/grafana/";         name = "Grafana";         vm = "oci-flex";      port = "3016"; auth = "Authelia + Bearer"; avail = "Wake"; }
      { domain = "app.diegonmarcos.com/gitea/";           name = "Gitea";           vm = "oci-flex";      port = "3000"; auth = "Authelia + Bearer"; avail = "Wake"; }
    ];

    securityLayers = [
      { n = "1"; name = "Network Edge";     desc = "Cloudflare Proxy + Cloud Firewalls"; }
      { n = "2"; name = "TLS Termination";  desc = "Caddy auto-HTTPS + Let's Encrypt"; }
      { n = "3"; name = "Traffic Filtering"; desc = "Rate limiting, bot blocking, scanner blocking"; }
      { n = "4"; name = "Authentication";   desc = "Authelia 2FA (TOTP/WebAuthn) + OIDC bearer tokens"; }
      { n = "5"; name = "Token Validation"; desc = "introspect-proxy OIDC introspection sidecar"; }
      { n = "6"; name = "Network Isolation"; desc = "WireGuard mesh VPN + Docker bridge networks"; }
      { n = "7"; name = "Credential Mgmt";  desc = "Vaultwarden (passwords) + Aegis (TOTP)"; }
    ];

    # ── Firewall & Ports data ──────────────────────────────────────
    firewallRules = [
      # gcp-proxy — public-facing reverse proxy
      { vm = "gcp-proxy"; ip = gcp; port = "22/tcp";    bind = "0.0.0.0"; purpose = "SSH";              status = "open"; }
      { vm = "gcp-proxy"; ip = gcp; port = "80/tcp";    bind = "0.0.0.0"; purpose = "Caddy HTTP";       status = "open"; }
      { vm = "gcp-proxy"; ip = gcp; port = "443/tcp";   bind = "0.0.0.0"; purpose = "Caddy HTTPS";      status = "open"; }
      { vm = "gcp-proxy"; ip = gcp; port = "443/udp";   bind = "0.0.0.0"; purpose = "Caddy HTTP/3";     status = "open"; }
      { vm = "gcp-proxy"; ip = gcp; port = "51820/udp"; bind = "0.0.0.0"; purpose = "WireGuard";        status = "open"; }
      # oci-flex — mesh only
      { vm = "oci-flex";  ip = flex; port = "22/tcp";    bind = "0.0.0.0"; purpose = "SSH";              status = "restrict"; }
      { vm = "oci-flex";  ip = flex; port = "51820/udp"; bind = "0.0.0.0"; purpose = "WireGuard";        status = "open"; }
      # oci-mail — mesh + mail delivery
      { vm = "oci-mail";  ip = mail; port = "22/tcp";    bind = "0.0.0.0"; purpose = "SSH";              status = "restrict"; }
      { vm = "oci-mail";  ip = mail; port = "25/tcp";    bind = "0.0.0.0"; purpose = "SMTP (inbound)";   status = "open"; }
      { vm = "oci-mail";  ip = mail; port = "465/tcp";   bind = "0.0.0.0"; purpose = "SMTPS";            status = "open"; }
      { vm = "oci-mail";  ip = mail; port = "587/tcp";   bind = "0.0.0.0"; purpose = "SMTP Submission";  status = "open"; }
      { vm = "oci-mail";  ip = mail; port = "993/tcp";   bind = "0.0.0.0"; purpose = "IMAPS";            status = "open"; }
      { vm = "oci-mail";  ip = mail; port = "51820/udp"; bind = "0.0.0.0"; purpose = "WireGuard";        status = "open"; }
      # oci-analytics — mesh only
      { vm = "oci-analytics"; ip = analytics; port = "22/tcp";    bind = "0.0.0.0"; purpose = "SSH";       status = "restrict"; }
      { vm = "oci-analytics"; ip = analytics; port = "51820/udp"; bind = "0.0.0.0"; purpose = "WireGuard"; status = "open"; }
    ];

    dockerPorts = [
      # gcp-proxy containers (public-facing — OK on 0.0.0.0)
      { vm = "gcp-proxy"; container = "caddy";            port = "80";   bind = "0.0.0.0"; internal = "80";   note = "reverse proxy"; }
      { vm = "gcp-proxy"; container = "caddy";            port = "443";  bind = "0.0.0.0"; internal = "443";  note = "reverse proxy"; }
      { vm = "gcp-proxy"; container = "authelia";         port = "9091"; bind = "127.0.0.1"; internal = "9091"; note = "via Caddy"; }
      { vm = "gcp-proxy"; container = "rust-api";         port = "8080"; bind = "127.0.0.1"; internal = "8080"; note = "via Caddy"; }
      { vm = "gcp-proxy"; container = "flask-api";        port = "5000"; bind = "127.0.0.1"; internal = "5000"; note = "via Caddy"; }
      { vm = "gcp-proxy"; container = "introspect-proxy"; port = "4182"; bind = "docker";   internal = "4182"; note = "internal only"; }
      { vm = "gcp-proxy"; container = "vaultwarden";      port = "—";    bind = "docker";   internal = "80";   note = "via Caddy"; }
      { vm = "gcp-proxy"; container = "ntfy";             port = "8090"; bind = "127.0.0.1"; internal = "80";   note = "via Caddy"; }
      { vm = "gcp-proxy"; container = "dozzle";           port = "9999"; bind = "127.0.0.1"; internal = "8080"; note = "via Caddy"; }
      # oci-flex containers (WireGuard only)
      { vm = "oci-flex"; container = "photoprism";  port = "3013"; bind = flex; internal = "2342"; note = "WG only"; }
      { vm = "oci-flex"; container = "nocodb";      port = "8085"; bind = flex; internal = "8080"; note = "WG only"; }
      { vm = "oci-flex"; container = "code-server"; port = "8443"; bind = flex; internal = "8443"; note = "WG only"; }
      { vm = "oci-flex"; container = "grist";       port = "3011"; bind = flex; internal = "8484"; note = "WG only"; }
      { vm = "oci-flex"; container = "etherpad";    port = "3012"; bind = flex; internal = "9001"; note = "WG only"; }
      { vm = "oci-flex"; container = "filebrowser"; port = "3015"; bind = flex; internal = "80";   note = "WG only"; }
      { vm = "oci-flex"; container = "hedgedoc";    port = "3010"; bind = flex; internal = "3000"; note = "WG only"; }
      { vm = "oci-flex"; container = "revealmd";    port = "3014"; bind = flex; internal = "1948"; note = "WG only"; }
      { vm = "oci-flex"; container = "gitea";       port = "3000"; bind = flex; internal = "3000"; note = "WG only"; }
      { vm = "oci-flex"; container = "gitea-ssh";   port = "2222"; bind = flex; internal = "22";   note = "WG only"; }
      { vm = "oci-flex"; container = "grafana";     port = "3016"; bind = flex; internal = "3000"; note = "WG only"; }
      { vm = "oci-flex"; container = "loki";        port = "3017"; bind = flex; internal = "3100"; note = "WG only"; }
      { vm = "oci-flex"; container = "tempo";       port = "3018"; bind = flex; internal = "3200"; note = "WG only"; }
      { vm = "oci-flex"; container = "mimir";       port = "3019"; bind = flex; internal = "8080"; note = "WG only"; }
      # oci-mail containers (WG + mail public)
      { vm = "oci-mail"; container = "mailu-front"; port = "25";   bind = "0.0.0.0"; internal = "25";   note = "SMTP public"; }
      { vm = "oci-mail"; container = "mailu-front"; port = "465";  bind = "0.0.0.0"; internal = "465";  note = "SMTPS public"; }
      { vm = "oci-mail"; container = "mailu-front"; port = "587";  bind = "0.0.0.0"; internal = "587";  note = "submission public"; }
      { vm = "oci-mail"; container = "mailu-front"; port = "993";  bind = "0.0.0.0"; internal = "993";  note = "IMAPS public"; }
      { vm = "oci-mail"; container = "mailu-front"; port = "8444"; bind = mail; internal = "443";  note = "WG only"; }
      { vm = "oci-mail"; container = "syncthing";   port = "8384"; bind = mail; internal = "8384"; note = "WG only"; }
      { vm = "oci-mail"; container = "syncthing";   port = "22000"; bind = "0.0.0.0"; internal = "22000"; note = "P2P sync"; }
      { vm = "oci-mail"; container = "radicale";    port = "5232"; bind = mail; internal = "5232"; note = "WG only"; }
      # oci-analytics containers (WG only)
      { vm = "oci-analytics"; container = "matomo";   port = "8080"; bind = analytics; internal = "8080"; note = "WG only"; }
      { vm = "oci-analytics"; container = "windmill"; port = "8000"; bind = "127.0.0.1"; internal = "8000"; note = "localhost"; }
    ];

    # ── Security snippets ─────────────────────────────────────────

    # 1. Security headers (HSTS, anti-clickjacking, etc.)
    securityHeaders = ''
      (security_headers) {
        header {
          Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
          X-Content-Type-Options "nosniff"
          X-Frame-Options "SAMEORIGIN"
          Referrer-Policy "strict-origin-when-cross-origin"
          Permissions-Policy "camera=(), microphone=(), geolocation=()"
          -Server
        }
      }
    '';

    # 2. Rate limiting (100 req/min per IP — requires caddy-ratelimit plugin)
    rateLimiting = ''
      (rate_limiting) {
        rate_limit {
          zone global {
            key    {remote_host}
            events 100
            window 1m
          }
        }
      }
    '';

    # 3. Bot blocking (known malicious scanners only)
    blockBots = ''
      (block_bots) {
        @bad_bots header_regexp User-Agent "(?i)(sqlmap|nikto|masscan|nmap|zgrab|scrapy|dirbuster|gobuster|nuclei|wfuzz|havij|acunetix|nessus|openvas)"
        respond @bad_bots 403
      }
    '';

    # 4. Scanner path blocking (common exploit paths)
    blockScanners = ''
      (block_scanners) {
        @blocked_paths path /wp-admin* /wp-login* /xmlrpc.php /.env /.git* /phpmyadmin* /actuator* /solr* /console* /.aws* /cgi-bin/*
        respond @blocked_paths 404
      }
    '';

    # 5. Request size limits (10MB default)
    requestLimits = ''
      (request_limits) {
        request_body {
          max_size 10MB
        }
      }
    '';

    # 6. IP blocking (placeholder — ready to activate)
    ipBlock = ''
      (ip_block) {
        # @blocked_ips remote_ip 192.0.2.0/24
        # respond @blocked_ips 403
      }
    '';

    # 7. Access logging (JSON to mounted volume for fail2ban)
    accessLog = ''
      (access_log) {
        log {
          output file /var/log/caddy/access.log {
            roll_size 10mb
            roll_keep 5
          }
          format json
        }
      }
    '';

    # Combined security snippet (imports all layers)
    securitySnippet = ''
      (security) {
        import security_headers
        import block_bots
        import block_scanners
        import rate_limiting
        import ip_block
        import access_log
      }
    '';

    # Per-site imports: sec = full security + size limit, secNoLimit = security only
    sec = ''
        import security
        import request_limits'';

    secNoLimit = ''
        import security'';

    # ── Auth snippets ────────────────────────────────────────────
    # Authelia forward_auth (cookie-based, for browser sessions)
    authelia = ''
        forward_auth authelia:9091 {
          uri /api/authz/forward-auth
          copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        }'';

    # Bearer token auth via introspect-proxy sidecar (OIDC token introspection)
    bearer = ''
        forward_auth introspect-proxy:4182 {
          uri /auth
          copy_headers X-Auth-User X-Auth-Subject X-Auth-Email
        }'';

    # Site-level error handler for connection failures AND HTTP errors
    handleErrors = ''
      handle_errors {
        @backend_error expression `{err.status_code} == 502 || {err.status_code} == 503 || {err.status_code} == 504`
        handle @backend_error {
          root * /srv
          rewrite * /error.html
          file_server
        }
      }'';

    # Reusable protected block: bearer token → introspect-proxy, cookie → authelia
    mkProtected = upstream: ''
      @bearer header Authorization Bearer*
      handle @bearer {
    ${bearer}
        reverse_proxy ${upstream}
      }
      handle {
    ${authelia}
        reverse_proxy ${upstream}
      }
    '';

    # GitHub Pages reverse proxy (keeps subdomain URL in browser)
    mkGithubProxy = path: ''
      rewrite * /${path}{uri}
      reverse_proxy https://diegonmarcos.github.io {
        header_up Host diegonmarcos.github.io
      }
    '';

    # Same but with custom reverse_proxy block (for tls_insecure_skip_verify etc.)
    mkProtectedCustom = upstreamUrl: transportBlock: ''
      @bearer header Authorization Bearer*
      handle @bearer {
    ${bearer}
        reverse_proxy ${upstreamUrl} {
          ${transportBlock}
        }
      }
      handle {
    ${authelia}
        reverse_proxy ${upstreamUrl} {
          ${transportBlock}
        }
      }
    '';

    # ── Dashboard generation ───────────────────────────────────────

    mkDashboardMd = let
      vmRows = builtins.concatStringsSep "\n" (map (v:
        "| **${v.alias}** | ${v.provider} | ${v.tier} | `${v.ip}` | `${v.wg}` | ${v.ram} | ${v.cpu} | ${v.availability} |"
      ) (builtins.attrValues vms));
      svcRows = builtins.concatStringsSep "\n" (map (s:
        "| `${s.domain}` | **${s.name}** | ${s.vm} | ${s.port} | ${s.auth} | ${s.avail} |"
      ) services);
      secRows = builtins.concatStringsSep "\n" (map (l:
        "| ${l.n} | **${l.name}** | ${l.desc} |"
      ) securityLayers);
      fwRows = builtins.concatStringsSep "\n" (map (r:
        "| **${r.vm}** | `${r.ip}` | ${r.port} | ${r.bind} | ${r.purpose} | ${if r.status == "open" then "OPEN" else "RESTRICT"} |"
      ) firewallRules);
      dkRows = builtins.concatStringsSep "\n" (map (d:
        "| **${d.vm}** | ${d.container} | ${d.port} | `${d.bind}` | ${d.internal} | ${d.note} |"
      ) dockerPorts);
    in ''
# Infrastructure Dashboard

*proxy.diegonmarcos.com* — generated from Nix flake at build time

---

## Virtual Machines

| Alias | Provider | Tier | Public IP | WG IP | RAM | CPU | Availability |
|-------|----------|------|-----------|-------|-----|-----|--------------|
${vmRows}

---

## Services

| Domain | Service | VM | Port | Auth | Availability |
|--------|---------|-----|------|------|--------------|
${svcRows}

---

## Security Stack

| Layer | Name | Description |
|-------|------|-------------|
${secRows}

---

## Firewall & Ports

Cloud firewall rules and host-level iptables. Only **gcp-proxy** should accept public traffic.
OCI VMs restrict to WireGuard mesh + mail delivery ports.

| VM | WG IP | Port | Bind | Purpose | Status |
|----|-------|------|------|---------|--------|
${fwRows}

**iptables policy per VM:**

| VM | Chain | Rule | Purpose |
|----|-------|------|---------|
| gcp-proxy | FORWARD | `10.0.0.0/24 → wg0 ACCEPT` | WireGuard mesh routing |
| gcp-proxy | POSTROUTING | `10.0.0.0/24 MASQUERADE` | NAT for mesh hub |
| gcp-proxy | INPUT | `51820/udp ACCEPT` | WireGuard endpoint |
| oci-flex | INPUT | `51820/udp ACCEPT` | WireGuard endpoint |
| oci-flex | INPUT | `22/tcp from 10.0.0.0/24 ACCEPT` | SSH via mesh only |
| oci-flex | INPUT | `default DROP` (except established) | Block public access |
| oci-mail | INPUT | `25,465,587,993/tcp ACCEPT` | Mail delivery (public) |
| oci-mail | INPUT | `51820/udp ACCEPT` | WireGuard endpoint |
| oci-mail | INPUT | `other DROP` (except established) | Block non-mail public |
| oci-analytics | INPUT | `51820/udp ACCEPT` | WireGuard endpoint |
| oci-analytics | INPUT | `22/tcp from 10.0.0.0/24 ACCEPT` | SSH via mesh only |
| oci-analytics | INPUT | `default DROP` (except established) | Block public access |

---

## Docker Network

Container port bindings. `0.0.0.0` = publicly exposed, `10.0.0.x` = WireGuard mesh only, `127.0.0.1` = localhost, `docker` = internal network.

| VM | Container | Host Port | Bind | Internal | Note |
|----|-----------|-----------|------|----------|------|
${dkRows}

**Docker network topology:**

```
┌─── npm_default (bridge) ──────────────────────────────────┐
│                                                            │
│  gcp-proxy:  caddy ←→ authelia ←→ introspect-proxy        │
│              rust-api, flask-api, vaultwarden, ntfy        │
│              dozzle (monitors all containers)              │
│                                                            │
│  oci-flex:   photoprism ←→ photoprism-db (redis)          │
│              nocodb, code-server, grist, gitea             │
│              etherpad, filebrowser, hedgedoc, revealmd     │
│              grafana ←→ loki ←→ tempo ←→ mimir (LGTM)    │
│                                                            │
│  oci-mail:   mailu (front/smtp/imap/admin/webmail/redis)  │
│              syncthing, radicale, caddy (local proxy)      │
│                                                            │
│  oci-analytics: matomo, windmill                           │
└────────────────────────────────────────────────────────────┘
```

---

## Auth Flow

```
Browser Request
    │
    ▼
┌─────────────┐
│  Cloudflare  │  DNS + DDoS + WAF
└──────┬──────┘
       │
       ▼
┌─────────────┐
│    Caddy     │  TLS termination, security headers,
│  (gcp-proxy) │  rate limiting, bot/scanner blocking
└──────┬──────┘
       │
   ┌───┴───┐
   │       │
Bearer?  Cookie?
   │       │
   ▼       ▼
┌──────┐ ┌──────────┐
│intro-│ │ Authelia  │  TOTP / WebAuthn
│spect │ │   2FA    │
└──┬───┘ └────┬─────┘
   │          │
   └────┬─────┘
        │
        ▼
┌─────────────┐
│  WireGuard   │  Encrypted mesh to target VM
│   tunnel     │
└──────┬──────┘
       │
       ▼
  [ Service ]
```

---

## Network Topology

```
Internet
    │
    ▼
┌─────────────────────────────────────────────┐
│  Cloudflare  (*.diegonmarcos.com)            │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│  gcp-proxy  ${gcp}                           │
│  ├─ Caddy (reverse proxy)                    │
│  ├─ Authelia (2FA)                           │
│  ├─ introspect-proxy (OIDC)                  │
│  ├─ Vaultwarden                              │
│  ├─ ntfy                                     │
│  └─ Flask API + Rust API                     │
└────┬──────────┬──────────┬───────────────────┘
     │ wg0      │ wg0      │ wg0
     ▼          ▼          ▼
┌─────────┐ ┌─────────┐ ┌──────────────┐
│oci-flex │ │oci-mail │ │oci-analytics │
│ ${flex} │ │ ${mail} │ │ ${analytics} │
│         │ │         │ │              │
│PhotoPrism│ │ Mailu  │ │   Matomo     │
│ NocoDB  │ │Syncthing│ │  Windmill    │
│Code Srv │ │Radicale │ │              │
│ AFFiNE  │ │         │ │              │
│  Grist  │ │         │ │              │
└─────────┘ └─────────┘ └──────────────┘
```

---

`visitor@caddy:~$` [cd /home](https://linktree.diegonmarcos.com)
    '';

    dashboardTemplate = pkgs: pkgs.writeText "dashboard.html.template" ''
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>$title$</title>
      <style>
      *{margin:0;padding:0;box-sizing:border-box}
      body{
        background:#0a0a0f;
        color:#c0c0c0;
        font-family:'Courier New',monospace;
        min-height:100vh;
        overflow-x:hidden;
        position:relative;
        padding:2rem 1rem;
      }
      .stars{
        position:fixed;
        top:0;left:0;width:100%;height:100%;
        pointer-events:none;
        z-index:0;
      }
      .star{
        position:absolute;
        border-radius:50%;
        background:#fff;
        animation:twinkle var(--d,3s) ease-in-out infinite alternate;
      }
      @keyframes twinkle{0%{opacity:.1}100%{opacity:.8}}
      .container{
        position:relative;
        z-index:1;
        max-width:960px;
        margin:0 auto;
        padding:1rem;
      }
      h1{
        font-size:clamp(1.5rem,4vw,2.5rem);
        font-weight:bold;
        background:linear-gradient(135deg,#845ef7,#339af0,#51cf66);
        -webkit-background-clip:text;
        -webkit-text-fill-color:transparent;
        background-clip:text;
        text-align:center;
        margin-bottom:1.5rem;
      }
      h2{
        color:#845ef7;
        font-size:1.1rem;
        margin:2rem 0 .75rem;
        border-bottom:1px solid #1a1a2e;
        padding-bottom:.3rem;
      }
      p,li{line-height:1.6;margin:.5rem 0}
      em{color:#fcc419;font-style:normal}
      strong{color:#ff6b6b}
      code{
        color:#51cf66;
        background:#0d0d15;
        padding:.15rem .4rem;
        border-radius:3px;
        font-size:.85em;
      }
      pre{
        background:#0d0d15;
        border:1px solid #1a1a2e;
        border-radius:4px;
        padding:1rem;
        overflow-x:auto;
        font-size:.75rem;
        line-height:1.5;
        color:#868e96;
        margin:1rem 0;
      }
      pre code{background:none;padding:0;color:inherit}
      a{
        color:#339af0;
        text-decoration:none;
        border-bottom:1px dashed #339af0;
        transition:color .2s;
      }
      a:hover{color:#845ef7;border-color:#845ef7}
      hr{border:none;border-top:1px solid #1a1a2e;margin:1.5rem 0}
      table{
        width:100%;
        border-collapse:collapse;
        margin:1rem 0;
        font-size:.75rem;
        display:block;
        overflow-x:auto;
      }
      th{
        background:#0d0d15;
        color:#51cf66;
        text-align:left;
        padding:.5rem .6rem;
        border:1px solid #1a1a2e;
        white-space:nowrap;
      }
      td{
        padding:.4rem .6rem;
        border:1px solid #1a1a2e;
        white-space:nowrap;
      }
      tr:hover td{background:#0d0d15}
      .prompt{
        text-align:center;
        margin-top:2rem;
        font-size:.9rem;
        color:#495057;
      }
      .prompt span{
        color:#51cf66;
        animation:blink 1s step-end infinite;
      }
      @keyframes blink{0%,50%{opacity:1}51%,100%{opacity:0}}
      @media(max-width:600px){
        table{font-size:.65rem}
        pre{font-size:.65rem}
      }
      </style>
      </head>
      <body>
      <div class="stars" id="stars"></div>
      <div class="container">
      $body$
      </div>
      <script>
      (function(){
        var s=document.getElementById('stars'),w=window.innerWidth,h=window.innerHeight;
        for(var i=0;i<80;i++){
          var d=document.createElement('div');
          d.className='star';
          var sz=Math.random()*2+1;
          d.style.cssText='width:'+sz+'px;height:'+sz+'px;top:'+Math.random()*h+'px;left:'+Math.random()*w+'px;--d:'+(Math.random()*4+2)+'s';
          s.appendChild(d);
        }
      })();
      </script>
      </body>
      </html>
    '';

    mkCaddyfile = pkgs: pkgs.writeText "Caddyfile" ''
      {
        admin localhost:${toString config.admin_port}
        order respond before handle
      }

      # ════════════════════════════════════════════════════════════
      # SECURITY SNIPPETS
      # ════════════════════════════════════════════════════════════

      ${securityHeaders}
      ${rateLimiting}
      ${blockBots}
      ${blockScanners}
      ${requestLimits}
      ${ipBlock}
      ${accessLog}
      ${securitySnippet}

      # ════════════════════════════════════════════════════════════
      # PUBLIC / BYPASS (no auth)
      # ════════════════════════════════════════════════════════════

      # Authelia itself — must be public (bypass policy in Authelia config)
      auth.diegonmarcos.com {
    ${sec}
        reverse_proxy authelia:9091
        ${handleErrors}
      }

      # API — Rust (public), Flask (protected)
      api.diegonmarcos.com {
    ${sec}
        handle /rust/* {
          reverse_proxy ${gcp}:8080
        }
        handle {
          ${mkProtected "${gcp}:5000"}
        }
        ${handleErrors}
      }

      # Radicale CalDAV/CardDAV
      cal.diegonmarcos.com {
    ${sec}
        reverse_proxy ${flex}:5232
        ${handleErrors}
      }

      # Affine collaborative docs (100MB uploads, long timeouts)
      drive-notes-affine.diegonmarcos.com {
    ${secNoLimit}
        request_body {
          max_size 100MB
        }
        reverse_proxy ${flex}:3010 {
          transport http {
            read_timeout 3600s
            write_timeout 3600s
          }
        }
        ${handleErrors}
      }

      # ── GitHub Pages reverse proxies (URL stays as subdomain) ──

      # Landing page
      diegonmarcos.com, www.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "landpage"}
        ${handleErrors}
      }

      # Linktree
      linktree.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "linktree"}
        ${handleErrors}
      }

      # Cloud dashboard
      cloud.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "cloud"}
        ${handleErrors}
      }

      # Nexus
      nexus.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "nexus"}
        ${handleErrors}
      }

      # Suite apps dashboard
      suite.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "suite"}
        ${handleErrors}
      }

      # Maps
      maps.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "mymaps"}
        ${handleErrors}
      }

      # ════════════════════════════════════════════════════════════
      # ANALYTICS — Matomo (public tracking + protected admin)
      # ════════════════════════════════════════════════════════════

      analytics.diegonmarcos.com {
    ${sec}
        # Public tracking endpoints (no auth — called by portfolio sites)
        @tracking {
          path /matomo.js /matomo.php /piwik.js /piwik.php /collect.php /api.php /track.php
          path /js/*
        }
        handle @tracking {
          reverse_proxy ${analytics}:8080
        }

        # Protected admin dashboard
        ${mkProtected "${analytics}:8080"}

        ${handleErrors}
      }

      # ════════════════════════════════════════════════════════════
      # AUTHELIA-PROTECTED (bearer token bypass for CLI/API)
      # ════════════════════════════════════════════════════════════

      # PhotoPrism
      photos.diegonmarcos.com {
    ${sec}
        # Root path → landing page (replaces Cloudflare redirect rule)
        @root path /
        handle @root {
          redir https://diegonmarcos.github.io/myphotos/ permanent
        }

        # All other paths → auth + PhotoPrism
        ${mkProtected "${flex}:3013"}
        ${handleErrors}
      }

      # Syncthing
      sync.diegonmarcos.com {
    ${sec}
        ${mkProtected "${mail}:8384"}
        ${handleErrors}
      }

      # Mailu webmail (upstream is HTTPS with self-signed cert)
      mail.diegonmarcos.com {
    ${sec}
        # Root path → landing page (replaces Cloudflare redirect rule)
        @root path /
        handle @root {
          redir https://diegonmarcos.github.io/mymail/ permanent
        }

        # All other paths → auth + Mailu
        ${mkProtectedCustom "https://${mail}:8444" ''
          transport http {
            tls_insecure_skip_verify
          }''}
        ${handleErrors}
      }

      # Code Server IDE (WebSocket support is automatic in Caddy)
      ide.diegonmarcos.com {
    ${sec}
        ${mkProtected "${flex}:8443"}
        ${handleErrors}
      }

      # NocoDB
      db.diegonmarcos.com {
    ${sec}
        ${mkProtected "${flex}:8085"}
        ${handleErrors}
      }

      # App hub (path-based routing)
      app.diegonmarcos.com {
    ${sec}
        handle_path /windmill/* {
          ${mkProtected "${analytics}:8000"}
        }
        handle_path /etherpad/* {
          ${mkProtected "${flex}:3012"}
        }
        handle_path /filebrowser/* {
          ${mkProtected "${flex}:3015"}
        }
        handle_path /hedgedoc/* {
          ${mkProtected "${flex}:3010"}
        }
        handle_path /revealmd/* {
          ${mkProtected "${flex}:3014"}
        }
        handle_path /dozzle/* {
          ${mkProtected "${gcp}:9999"}
        }
        handle_path /grafana/* {
          ${mkProtected "${flex}:3016"}
        }
        handle_path /gitea/* {
          ${mkProtected "${flex}:3000"}
        }
        handle {
          respond "Not Found" 404
        }
        ${handleErrors}
      }

      # Grist Sheets
      sheets.diegonmarcos.com {
    ${sec}
        ${mkProtected "${flex}:3011"}
        ${handleErrors}
      }

      # Infrastructure dashboard (static HTML generated from flake data)
      proxy.diegonmarcos.com {
    ${sec}
        @bearer header Authorization Bearer*
        handle @bearer {
    ${bearer}
          root * /srv
          rewrite * /dashboard.html
          file_server
        }
        handle {
    ${authelia}
          root * /srv
          rewrite * /dashboard.html
          file_server
        }
        ${handleErrors}
      }

      # Vaultwarden — reachable via npm_default docker network
      # Authelia access_control handles: API/identity/icons bypass, admin two_factor
      vault.diegonmarcos.com {
    ${sec}
        ${mkProtected "vaultwarden:80"}
        ${handleErrors}
      }

      # ntfy notifications
      rss.diegonmarcos.com {
    ${sec}
        ${mkProtected "${gcp}:8090"}
        ${handleErrors}
      }

      # ════════════════════════════════════════════════════════════
      # CATCH-ALL — Custom error page for unknown/unconfigured domains
      # ════════════════════════════════════════════════════════════

      *.diegonmarcos.com {
    ${secNoLimit}
        tls {
          dns cloudflare {env.CF_API_TOKEN}
        }
        root * /srv
        rewrite * /error.html
        file_server
      }

    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        caddy:
          image: ghcr.io/diegonmarcos/caddy-custom:latest
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .secrets
          ports:
            - "${toString config.http_port}:80"
            - "${toString config.https_port}:443"
            - "${toString config.https_port}:443/udp"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - ./error.html:/srv/error.html:ro
            - ./dashboard.html:/srv/dashboard.html:ro
            - ./logs:/var/log/caddy
            - caddy_data:/data
            - caddy_config:/config
          networks:
            - npm_default
          depends_on:
            introspect-proxy:
              condition: service_healthy

        introspect-proxy:
          build: ./introspect-proxy
          image: introspect-proxy:latest
          container_name: introspect-proxy
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            INTROSPECT_URL: https://auth.diegonmarcos.com/api/oidc/introspection
            CLIENT_ID: cli
            CLIENT_SECRET: ''${AUTHELIA_CLI_SECRET}
          networks:
            - npm_default
          deploy:
            resources:
              limits:
                memory: 96M
              reservations:
                memory: 48M
          healthcheck:
            test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:4182/health')"]
            interval: 30s
            timeout: 5s
            retries: 3
            start_period: 10s

      volumes:
        caddy_data:
          driver: local
        caddy_config:
          driver: local

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "caddy-configs" {
        nativeBuildInputs = [ pkgs.pandoc ];
      } ''
        mkdir -p $out/introspect-proxy/app
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkCaddyfile pkgs} $out/Caddyfile
        cp ${./error.html} $out/error.html
        pandoc --from=markdown --to=html5 --standalone \
          --template=${dashboardTemplate pkgs} \
          --metadata title="Infrastructure Dashboard" \
          -o $out/dashboard.html \
          ${pkgs.writeText "dashboard.md" mkDashboardMd}
        cp ${./introspect-proxy/Dockerfile} $out/introspect-proxy/Dockerfile
        cp ${./introspect-proxy/app/main.py} $out/introspect-proxy/app/main.py
        cp ${./introspect-proxy/app/requirements.txt} $out/introspect-proxy/app/requirements.txt
      '';
    });
  };
}
