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
    flex = "10.0.0.2";      # oci-apps-1 (on-demand)
    flex0 = "10.0.0.6";     # oci-apps (on-demand)
    mail = "10.0.0.3";      # oci-mail
    analytics = "10.0.0.4"; # oci-analytics
    flex2 = "10.0.0.7";     # oci-apps-2
    gpu = "10.0.0.8";       # gcp-ollama (gcp-t4)

    # ── Dashboard data (imported from centralized JSON files) ─────
    readJSON = file: builtins.fromJSON (builtins.readFile (./data + "/${file}"));

    vms             = readJSON "vms.json";
    services        = readJSON "services.json";
    securityLayers  = readJSON "security.json";
    firewallRules   = readJSON "firewall.json";
    dockerPorts     = readJSON "docker_ports.json";
    dnsData         = readJSON "dns.json";

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

      # Declared containers summary (grouped by VM)
      groupedByVM = builtins.groupBy (d: d.vm) dockerPorts;
      declContRows = builtins.concatStringsSep "\n" (map (vmName:
        let
          entries = groupedByVM.${vmName};
          containers = map (e: e.container) entries;
          unique = builtins.attrNames (builtins.listToAttrs (map (c: { name = c; value = true; }) containers));
        in
        "| **${vmName}** | ${toString (builtins.length unique)} | ${builtins.concatStringsSep ", " unique} |"
      ) (builtins.attrNames groupedByVM));

      # DNS tables
      cfDnsRows = builtins.concatStringsSep "\n" (map (r:
        "| ${r.type} | `${r.name}` | `${r.value}` | ${toString r.ttl} | ${r.purpose} |"
      ) dnsData.cloudflare);
      hickoryFwdRows = builtins.concatStringsSep "\n" (map (r:
        "| `${r.name}.internal` | `${r.ip}` | ${r.vm} | ${r.purpose} |"
      ) dnsData.hickory.forward);
      hickoryRevRows = builtins.concatStringsSep "\n" (map (r:
        "| `${r.ip}` | `${r.hostname}` | ${r.vm} |"
      ) dnsData.hickory.reverse);
      emailAuthRows = builtins.concatStringsSep "\n" (map (r:
        "| ${r.type} | `${r.name}` | `${r.value}` | ${r.purpose} |"
      ) dnsData.email_auth);
    in ''
# Infrastructure Dashboard

*proxy.diegonmarcos.com* — generated from Nix flake at build time

---

<div class="tab-bar">
<button class="tab-btn active" data-tab="proxy">Reverse Proxy</button>
<button class="tab-btn" data-tab="security">Security</button>
<button class="tab-btn" data-tab="health">Health</button>
<button class="tab-btn" data-tab="dns">DNS</button>
</div>

<div class="tab-content active" id="tab-proxy">

## Reverse Proxying

<button class="rbtn" id="toggle-svcs">Show Live</button>
<div id="live-svcs" class="tier-body" style="display:none"></div>

| Domain | Service | VM | Port | Auth | Availability |
|--------|---------|-----|------|------|--------------|
${svcRows}

---

## Auth Flow

```
Browser Request
    │
    ▼
┌─────────────┐
│  Cloudflare  │  DNS only (grey cloud, no proxy)
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

## Docker Network

<button class="rbtn" id="toggle-docker">Show Live</button>
<div id="live-docker" class="tier-body" style="display:none"></div>

| VM | Container | Host Port | Bind Address | Internal | Note |
|----|-----------|-----------|--------------|----------|------|
${dkRows}

---

## Network Topology

```
Internet
    │
    ▼
┌─────────────────────────────────────────────┐
│  Cloudflare  (*.diegonmarcos.com) DNS only   │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│  gcp-proxy  ${gcp}                           │
│  ├─ Caddy (reverse proxy + TLS)              │
│  ├─ Authelia (2FA) + introspect-proxy        │
│  ├─ Flask API + Go API                       │
│  ├─ Vaultwarden, ntfy, Dozzle               │
│  └─ Sauron Central + Syslog Central          │
└────┬──────────┬──────────┬──────┬───────────┬──────────┘
     │ wg0      │ wg0      │ wg0  │ wg0       │ wg0
     ▼          ▼          ▼      ▼           ▼
┌──────────┐ ┌──────────┐ ┌─────────┐ ┌────────────┐
│oci-apps  │ │oci-apps-1│ │oci-mail │ │oci-analyti.│
│ ${flex0} │ │ ${flex}  │ │ ${mail} │ │${analytics}│
│          │ │          │ │         │ │            │
│Rust API  │ │PhotoPrism│ │ Mailu   │ │  Matomo    │
│Crawlee   │ │ NocoDB   │ │Syncthing│ │  Windmill  │
│Quant Lab │ │Code Srv  │ │Radicale │ │            │
│          │ │ AFFiNE   │ │         │ │            │
│          │ │Grist,LGTM│ │         │ │            │
│          │ │Gitea,Ethr│ │         │ │            │
└──────────┘ └──────────┘ └─────────┘ └────────────┘

┌──────────┐ ┌──────────┐
│oci-apps-2│ │gcp-ollama│
│ ${flex2} │ │ ${gpu}   │
│          │ │          │
│(on-demand│ │ Ollama   │
│ compute) │ │ LLM      │
└──────────┘ └──────────┘
```

</div>

<div class="tab-content" id="tab-security">

## Security Stack

| Layer | Name | Description |
|-------|------|-------------|
${secRows}

---

## Firewall & Ports

Only **gcp-proxy** accepts public HTTP/HTTPS traffic. All other VMs restrict to WireGuard mesh + service-specific ports.

| VM | WG IP | Port | Bind | Purpose | Status |
|----|-------|------|------|---------|--------|
${fwRows}

**Policy**: All VMs run `51820/udp` (WireGuard) + `22/tcp` (SSH restricted). gcp-proxy additionally exposes `80/443` (Caddy). oci-mail exposes `25,465,587,993` (mail delivery).

### iptables / nftables

| Chain | Policy | Notes |
|-------|--------|-------|
| INPUT | DROP (cloud firewall) | Only allowed ports above reach the VM |
| FORWARD | ACCEPT (Docker) | Docker manages container routing via nftables |
| OUTPUT | ACCEPT | No egress filtering |
| DOCKER-USER | ACCEPT | Default — no extra restrictions |
| wg0 | All traffic | Mesh peers trusted, no per-port filtering |

</div>

<div class="tab-content" id="tab-health">

## Virtual Machines

<button class="rbtn" id="toggle-vms">Show Live</button>
<div id="live-vms" class="tier-body" style="display:none"></div>

| Alias | Provider | Tier | Public IP | WG IP | RAM | CPU | Availability |
|-------|----------|------|-----------|-------|-----|-----|--------------|
${vmRows}

---

## Declared Containers

| VM | Count | Containers |
|----|-------|------------|
${declContRows}

---

<div id="health-section">
<h2>Live Health</h2>
<p>Lazy-loaded from <code>/api/health/*</code> and <code>/api/profiling/*</code>. Click <em>Refresh</em> to load each tier.</p>

<div class="health-tier">
<div class="tier-hdr"><h3>Declared <span class="tier-lbl">Tier 0 — Config (instant)</span></h3><button class="rbtn" id="btn-declared">Refresh</button></div>
<div class="tier-body" id="out-declared">—</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Deployed <span class="tier-lbl">Tier 1 — docker ps (~3s)</span></h3><button class="rbtn" id="btn-deployed">Refresh</button></div>
<div class="tier-body" id="out-deployed">—</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Drift <span class="tier-lbl">Tier 2 — Declared vs Deployed (~3s)</span></h3><button class="rbtn" id="btn-drift">Refresh</button></div>
<div class="tier-body" id="out-drift">—</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Status <span class="tier-lbl">Tier 3 — Comprehensive (heavy)</span></h3><button class="rbtn warn" id="btn-status">Refresh</button></div>
<div class="tier-body" id="out-status">—</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Profiling <span class="tier-lbl">Tier 4 — Deep Diagnostic (heaviest)</span></h3></div>
<div class="tier-body" id="out-profiling">Load <em>Declared</em> first, then trigger per-container.</div>
</div>
</div>

</div>

<div class="tab-content" id="tab-dns">

## Public DNS (Cloudflare)

*diegonmarcos.com* — all records point to gcp-proxy (35.226.147.64) except smtp/imap direct to oci-mail

| Type | Name | Value | TTL | Purpose |
|------|------|-------|-----|---------|
${cfDnsRows}

---

## Internal DNS (Hickory — .internal zone)

*WireGuard mesh only* — resolved by Hickory DNS on gcp-proxy:53

| Name | IP | VM | Purpose |
|------|-----|-----|---------|
${hickoryFwdRows}

---

## Reverse DNS (PTR)

| IP | Hostname | VM |
|-----|----------|-----|
${hickoryRevRows}

---

## Email Authentication

| Type | Name | Value | Purpose |
|------|------|-------|---------|
${emailAuthRows}

</div>

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
        .tab-bar{flex-wrap:wrap}
        .tab-btn{font-size:.6rem;padding:.3rem .5rem}
      }
      .tab-bar{
        display:flex;
        justify-content:center;
        gap:.5rem;
        margin:1.5rem 0;
      }
      .tab-btn{
        background:#1a1a2e;
        color:#c0c0c0;
        border:1px solid #1a1a2e;
        padding:.4rem .9rem;
        border-radius:3px;
        cursor:pointer;
        font-family:inherit;
        font-size:.75rem;
        transition:all .2s;
        border-bottom:2px solid transparent;
      }
      .tab-btn:hover{color:#fff;border-bottom-color:#339af0}
      .tab-btn.active{
        color:#fff;
        border-bottom:2px solid;
        border-image:linear-gradient(135deg,#845ef7,#339af0,#51cf66) 1;
      }
      .tab-content{display:none}
      .tab-content.active{display:block}
      .health-tier{
        margin:1rem 0;
        border:1px solid #1a1a2e;
        border-radius:4px;
        padding:.75rem 1rem;
      }
      .tier-hdr{
        display:flex;
        align-items:center;
        justify-content:space-between;
        margin-bottom:.5rem;
      }
      .tier-hdr h3{
        color:#339af0;
        font-size:.9rem;
        margin:0;
        font-weight:normal;
      }
      .tier-lbl{
        color:#495057;
        font-size:.65rem;
        margin-left:.5rem;
      }
      .rbtn{
        background:#1a1a2e;
        color:#51cf66;
        border:1px solid #51cf66;
        padding:.2rem .6rem;
        border-radius:3px;
        cursor:pointer;
        font-family:inherit;
        font-size:.7rem;
        transition:all .2s;
      }
      .rbtn:hover{background:#51cf66;color:#0a0a0f}
      .rbtn:disabled{opacity:.4;cursor:not-allowed}
      .rbtn.warn{border-color:#fcc419;color:#fcc419}
      .rbtn.warn:hover{background:#fcc419;color:#0a0a0f}
      .tier-body{font-size:.75rem;color:#868e96}
      .tier-body table{margin:.5rem 0}
      .st-ok{color:#51cf66}
      .st-warn{color:#fcc419}
      .st-err{color:#ff6b6b}
      .st-off{color:#495057}
      .loading{color:#339af0;font-style:italic}
      .prof-btn{
        background:none;
        color:#339af0;
        border:1px solid #1a1a2e;
        padding:.1rem .4rem;
        border-radius:2px;
        cursor:pointer;
        font-family:inherit;
        font-size:.65rem;
      }
      .prof-btn:hover{border-color:#339af0}
      .prof-btn.warn{color:#fcc419;border-color:#1a1a2e}
      .prof-btn.warn:hover{border-color:#fcc419}
      .prof-vm{margin:.5rem 0}
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
      // Tab switching
      document.querySelectorAll('.tab-btn').forEach(function(btn){
        btn.addEventListener('click',function(){
          document.querySelectorAll('.tab-btn').forEach(function(b){b.classList.remove('active')});
          document.querySelectorAll('.tab-content').forEach(function(c){c.classList.remove('active')});
          btn.classList.add('active');
          document.getElementById('tab-'+btn.dataset.tab).classList.add('active');
        });
      });
      // Health Dashboard
      var HAPI='https://api.diegonmarcos.com';
      function hfetch(path,elId,btnId,render){
        var el=document.getElementById(elId);
        var btn=document.getElementById(btnId);
        if(btn)btn.disabled=true;
        el.innerHTML='<span class="loading">loading...</span>';
        fetch(HAPI+path,{signal:AbortSignal.timeout(30000)})
          .then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);return r.json()})
          .then(function(d){render(el,d);if(btn)btn.disabled=false})
          .catch(function(e){el.innerHTML='<span class="st-err">Error: '+e.message+'</span>';if(btn)btn.disabled=false});
      }
      document.getElementById('btn-declared').addEventListener('click',function(){
        hfetch('/api/health/declared','out-declared','btn-declared',rDeclared);
      });
      document.getElementById('btn-deployed').addEventListener('click',function(){
        hfetch('/api/health/deployed','out-deployed','btn-deployed',rDeployed);
      });
      document.getElementById('btn-drift').addEventListener('click',function(){
        hfetch('/api/health/drift','out-drift','btn-drift',rDrift);
      });
      document.getElementById('btn-status').addEventListener('click',function(){
        hfetch('/api/health/status','out-status','btn-status',rStatus);
      });
      function rDeclared(el,d){
        var h='<table><tr><th>VM</th><th>Label</th><th>Services</th><th>Containers</th></tr>';
        var vms=d.vms||{};
        for(var id in vms){
          var v=vms[id],svcs=v.services||{},sc=Object.keys(svcs).length,cc=0;
          for(var s in svcs)cc+=svcs[s].length;
          h+='<tr><td>'+id+'</td><td>'+(v.label||"")+'</td><td>'+sc+'</td><td>'+cc+'</td></tr>';
        }
        h+='</table>';
        var t=d.totals||{};
        h+='<p>Total: <strong>'+t.vms+'</strong> VMs, <strong>'+t.services+'</strong> services, <strong>'+t.containers+'</strong> containers</p>';
        window._dVMs=d.vms;
        window._deployedData={};
        el.innerHTML=h;
        var pel=document.getElementById('out-profiling');
        if(pel)pel.innerHTML='<span class="loading">Fetching deployed state...</span>';
        fetch(HAPI+'/api/health/deployed',{signal:AbortSignal.timeout(30000)})
          .then(function(r){return r.json()})
          .then(function(dd){window._deployedData=dd.vms||{};rProfBtns()})
          .catch(function(){rProfBtns()});
      }
      function rDeployed(el,d){
        var h='''';
        var vms=d.vms||{};
        for(var id in vms){
          var v=vms[id],cs=v.containers||[];
          h+='<div class="health-tier" style="margin:.5rem 0;padding:.5rem .75rem;border-color:#1a1a2e">';
          h+='<strong>'+id+'</strong> ('+(v.label||"")+') — ';
          h+='<span class="st-ok">'+v.running+' running</span>, ';
          h+='<span class="'+(v.stopped>0?'st-warn':'st-off')+'">'+v.stopped+' stopped</span>';
          if(cs.length>0){
            h+='<table style="margin:.4rem 0"><tr><th>Container</th><th>State</th><th>Ports</th></tr>';
            for(var i=0;i<cs.length;i++){
              var c=cs[i],cls=c.state==='running'?'st-ok':(c.state==='exited'?'st-err':'st-warn');
              h+='<tr><td>'+c.name+'</td><td class="'+cls+'">'+c.state+'</td><td>'+(c.ports||'—')+'</td></tr>';
            }
            h+='</table>';
          }
          h+='</div>';
        }
        var sm=d.summary||{};
        h+='<p><span class="st-ok">'+sm.running+' running</span>, <span class="st-warn">'+sm.stopped+' stopped</span>, '+sm.total+' total</p>';
        el.innerHTML=h;
      }
      function rDrift(el,d){
        var h='<table><tr><th>VM</th><th>Declared</th><th>Deployed</th><th>Missing</th><th>Extra</th></tr>';
        var vms=d.vms||{};
        for(var id in vms){
          var v=vms[id];
          var ml=v.missing||[],xl=v.extra||[],dl=v.declared||[],dpl=v.deployed||[];
          h+='<tr><td>'+id+'</td><td>'+dl.length+'</td><td>'+dpl.length+'</td>';
          h+='<td class="'+(ml.length?'st-err':'st-ok')+'">'+(ml.length?ml.join(', '):'none')+'</td>';
          h+='<td class="'+(xl.length?'st-warn':'st-ok')+'">'+(xl.length?xl.join(', '):'none')+'</td></tr>';
        }
        h+='</table>';
        var sm=d.summary||{};
        h+='<p>Drift: '+(sm.drift?'<span class="st-err">YES</span>':'<span class="st-ok">NO</span>')+'</p>';
        el.innerHTML=h;
      }
      function rStatus(el,d){
        var h='<table><tr><th>VM</th><th>Label</th><th>Health</th><th>SSH</th><th>Ping</th><th>Containers</th></tr>';
        var vms=d.vms||{};
        for(var id in vms){
          var v=vms[id],sm=v.summary||{};
          var hc=v.health==='online'?'st-ok':(v.health==='degraded'?'st-warn':'st-err');
          h+='<tr><td>'+id+'</td><td>'+(v.label||"")+'</td>';
          h+='<td class="'+hc+'">'+v.health+'</td>';
          h+='<td class="'+(v.ssh?'st-ok':'st-err')+'">'+(v.ssh?'OK':'FAIL')+'</td>';
          h+='<td class="'+(v.ping?'st-ok':'st-err')+'">'+(v.ping?'OK':'FAIL')+'</td>';
          h+='<td>'+sm.containers_running+'/'+sm.containers_total+'</td></tr>';
        }
        h+='</table>';
        el.innerHTML=h;
      }
      function rProfBtns(){
        var el=document.getElementById('out-profiling');
        if(!window._dVMs){el.textContent='Load Declared first.';return}
        var dep=window._deployedData||{};
        var h="";
        for(var id in window._dVMs){
          var v=window._dVMs[id],svcs=v.services||{},cs=[];
          for(var s in svcs)for(var i=0;i<svcs[s].length;i++)cs.push(svcs[s][i]);
          var dv=dep[id]||{},dcs=dv.containers||[];
          var stMap={};for(var k=0;k<dcs.length;k++)stMap[dcs[k].name]={state:dcs[k].state,ports:dcs[k].ports||''''};
          var unhealthy=[];
          for(var j=0;j<cs.length;j++){var si=stMap[cs[j]];if(!si||si.state!=='running')unhealthy.push(cs[j])}
          h+='<div class="prof-vm"><strong>'+id+'</strong> ('+(v.label||"")+') — '+cs.length+' containers ';
          h+='<button class="prof-btn warn" data-profvm="'+id+'">Profile All</button> ';
          if(unhealthy.length>0)h+='<button class="prof-btn warn" data-profbad="'+id+'">Profile '+unhealthy.length+' Unhealthy</button>';
          h+='</div>';
          h+='<div id="profvm-'+id+'"></div>';
          h+='<table><tr><th>Container</th><th>State</th><th>Ports</th><th>Action</th><th>Result</th></tr>';
          for(var j=0;j<cs.length;j++){
            var cn=cs[j],si=stMap[cn];
            var st=si?si.state:'not deployed',pts=si?si.ports:'''';
            var cls=st==='running'?'st-ok':(st==='exited'||st==='not deployed'?'st-err':'st-warn');
            h+='<tr><td>'+cn+'</td><td class="'+cls+'">'+st+'</td><td>'+(pts||'—')+'</td>';
            h+='<td><button class="prof-btn" data-prof="'+cn+'">Profile</button></td>';
            h+='<td id="prof-'+cn+'"></td></tr>';
          }
          h+='</table>';
        }
        el.innerHTML=h;
      }
      document.getElementById('out-profiling').addEventListener('click',function(e){
        var t=e.target;
        if(t.dataset&&t.dataset.prof)profC(t.dataset.prof);
        if(t.dataset&&t.dataset.profvm)profVM(t.dataset.profvm);
        if(t.dataset&&t.dataset.profbad)profBad(t.dataset.profbad);
      });
      function profC(name){
        var el=document.getElementById('prof-'+name);
        if(el)el.innerHTML='<span class="loading"> checking...</span>';
        fetch(HAPI+'/api/profiling/'+encodeURIComponent(name),{signal:AbortSignal.timeout(60000)})
          .then(function(r){return r.json()})
          .then(function(d){
            var s=d.summary||{};
            var c=s.overall_status==='healthy'?'st-ok':(s.overall_status==='degraded'?'st-warn':'st-err');
            if(el)el.innerHTML=' <span class="'+c+'">'+s.overall_status+' ('+s.checks_passed+'/'+s.checks_total+', '+d.total_time_ms+'ms)</span>';
          })
          .catch(function(e){if(el)el.innerHTML=' <span class="st-err">'+e.message+'</span>'});
      }
      function profVM(vmId){
        var el=document.getElementById('profvm-'+vmId);
        if(el){el.className='loading';el.textContent='profiling all on '+vmId+'...';}
        fetch(HAPI+'/api/profiling/vm/'+encodeURIComponent(vmId),{signal:AbortSignal.timeout(120000)})
          .then(function(r){return r.json()})
          .then(function(d){
            var sm=d.summary||{},cs=d.containers||[];
            var h='<span class="st-ok">'+sm.healthy+' healthy</span>, <span class="st-warn">'+sm.degraded+' degraded</span>, <span class="st-err">'+sm.down+' down</span> ('+d.total_time_ms+'ms)<br>';
            for(var i=0;i<cs.length;i++){
              var c=cs[i],st=(c.summary||{}).overall_status||'unknown';
              var cls=st==='healthy'?'st-ok':(st==='degraded'?'st-warn':'st-err');
              h+='  <span class="'+cls+'">'+c.container+': '+st+'</span><br>';
              var cel=document.getElementById('prof-'+c.container);
              if(cel)cel.innerHTML=' <span class="'+cls+'">'+st+'</span>';
            }
            if(el){el.className="";el.innerHTML=h;}
          })
          .catch(function(e){if(el){el.className='st-err';el.textContent=vmId+': '+e.message;}});
      }
      function profBad(vmId){
        var dep=window._deployedData||{};
        var dv=dep[vmId]||{},dcs=dv.containers||[];
        var stMap={};for(var k=0;k<dcs.length;k++)stMap[dcs[k].name]=dcs[k].state;
        var v=window._dVMs[vmId];if(!v)return;
        var svcs=v.services||{},cs=[];
        for(var s in svcs)for(var i=0;i<svcs[s].length;i++)cs.push(svcs[s][i]);
        var bad=[];for(var j=0;j<cs.length;j++){var st=stMap[cs[j]];if(!st||st!=='running')bad.push(cs[j])}
        if(bad.length===0)return;
        var el=document.getElementById('profvm-'+vmId);
        if(el){el.className='loading';el.textContent='profiling '+bad.length+' unhealthy on '+vmId+'...';}
        var done=0,results=[];
        for(var j=0;j<bad.length;j++){
          (function(cn){
            fetch(HAPI+'/api/profiling/'+encodeURIComponent(cn),{signal:AbortSignal.timeout(60000)})
              .then(function(r){return r.json()})
              .then(function(d){
                var s=d.summary||{};
                var cls=s.overall_status==='healthy'?'st-ok':(s.overall_status==='degraded'?'st-warn':'st-err');
                results.push({name:cn,status:s.overall_status||'unknown',cls:cls,passed:s.checks_passed,total:s.checks_total,ms:d.total_time_ms});
                var cel=document.getElementById('prof-'+cn);
                if(cel)cel.innerHTML='<span class="'+cls+'">'+s.overall_status+' ('+s.checks_passed+'/'+s.checks_total+', '+d.total_time_ms+'ms)</span>';
              })
              .catch(function(e){
                results.push({name:cn,status:'error',cls:'st-err',err:e.message});
                var cel=document.getElementById('prof-'+cn);
                if(cel)cel.innerHTML='<span class="st-err">'+e.message+'</span>';
              })
              .finally(function(){
                done++;
                if(done===bad.length&&el){
                  var h='''';for(var r=0;r<results.length;r++){var ri=results[r];h+='<span class="'+ri.cls+'">'+ri.name+': '+ri.status+'</span><br>'}
                  el.className='''';el.innerHTML=h;
                }
              });
          })(bad[j]);
        }
      }
      // ── Toggle: Declared (static) ↔ Live (API) ──
      function setupToggle(btnId, liveId, fetchFn) {
        var btn = document.getElementById(btnId);
        if (!btn) return;
        var liveEl = document.getElementById(liveId);
        // The static table is the next sibling element after the live div
        var staticEl = liveEl.nextElementSibling;
        var loaded = false;
        btn.addEventListener('click', function() {
          if (liveEl.style.display === 'none') {
            if (staticEl) staticEl.style.display = 'none';
            liveEl.style.display = '''';
            btn.textContent = 'Show Declared';
            if (!loaded) { loaded = true; fetchFn(liveEl); }
          } else {
            if (staticEl) staticEl.style.display = '''';
            liveEl.style.display = 'none';
            btn.textContent = 'Show Live';
          }
        });
      }
      setupToggle('toggle-vms', 'live-vms', function(el) {
        el.innerHTML = '<span class="loading">Loading from API...</span>';
        fetch(HAPI + '/api/health/declared', {signal: AbortSignal.timeout(15000)})
          .then(function(r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
          .then(function(d) {
            var vms = d.vms || {}, t = d.totals || {};
            var h = '<table><tr><th>VM ID</th><th>Label</th><th>Services</th><th>Containers</th></tr>';
            for (var id in vms) {
              var v = vms[id], svcs = v.services || {}, sc = Object.keys(svcs).length, cc = 0;
              for (var s in svcs) cc += svcs[s].length;
              h += '<tr><td>' + id + '</td><td><strong>' + (v.label || '''') + '</strong></td><td>' + sc + '</td><td>' + cc + '</td></tr>';
            }
            h += '</table>';
            h += '<p><strong>' + t.vms + '</strong> VMs, <strong>' + t.services + '</strong> services, <strong>' + t.containers + '</strong> containers</p>';
            el.innerHTML = h;
          })
          .catch(function(e) { el.innerHTML = '<span class="st-err">Error: ' + e.message + '</span>'; });
      });
      setupToggle('toggle-svcs', 'live-svcs', function(el) {
        el.innerHTML = '<span class="loading">Loading from API...</span>';
        fetch(HAPI + '/api/health/declared', {signal: AbortSignal.timeout(15000)})
          .then(function(r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
          .then(function(d) {
            var vms = d.vms || {}, doms = d.domains || {};
            var h = '<table><tr><th>VM</th><th>Service</th><th>Containers</th><th>Domain</th></tr>';
            for (var id in vms) {
              var v = vms[id], svcs = v.services || {};
              for (var sn in svcs) {
                var cs = svcs[sn], dom = '''';
                for (var ci = 0; ci < cs.length; ci++) { if (doms[cs[ci]]) { dom = doms[cs[ci]]; break; } }
                h += '<tr><td>' + (v.label || id) + '</td><td><strong>' + sn + '</strong></td><td><code>' + cs.join('</code> <code>') + '</code></td>';
                h += '<td>' + (dom ? '<a href="https://' + dom + '" target="_blank">' + dom + '</a>' : '\u2014') + '</td></tr>';
              }
            }
            h += '</table>';
            el.innerHTML = h;
          })
          .catch(function(e) { el.innerHTML = '<span class="st-err">Error: ' + e.message + '</span>'; });
      });
      setupToggle('toggle-docker', 'live-docker', function(el) {
        el.innerHTML = '<span class="loading">Loading from API...</span>';
        fetch(HAPI + '/api/health/deployed', {signal: AbortSignal.timeout(30000)})
          .then(function(r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
          .then(function(d) {
            var dvms = d.vms || {}, h = '''';
            for (var id in dvms) {
              var v = dvms[id], cs = v.containers || [];
              h += '<div class="health-tier" style="margin:.5rem 0;padding:.5rem .75rem;border-color:#1a1a2e">';
              h += '<strong>' + (v.label || id) + '</strong> \u2014 ';
              h += '<span class="st-ok">' + v.running + ' running</span>, ';
              h += '<span class="' + (v.stopped > 0 ? 'st-warn' : 'st-off') + '">' + v.stopped + ' stopped</span>';
              if (cs.length > 0) {
                h += '<table style="margin:.4rem 0"><tr><th>Container</th><th>State</th><th>Ports</th></tr>';
                for (var j = 0; j < cs.length; j++) {
                  var c = cs[j], cls = c.state === 'running' ? 'st-ok' : (c.state === 'exited' ? 'st-err' : 'st-warn');
                  h += '<tr><td>' + c.name + '</td><td class="' + cls + '">' + c.state + '</td><td>' + (c.ports || '\u2014') + '</td></tr>';
                }
                h += '</table>';
              }
              h += '</div>';
            }
            var sm = d.summary || {};
            h += '<p><span class="st-ok">' + sm.running + ' running</span>, <span class="st-warn">' + sm.stopped + ' stopped</span>, ' + sm.total + ' total</p>';
            el.innerHTML = h;
          })
          .catch(function(e) { el.innerHTML = '<span class="st-err">Error: ' + e.message + '</span>'; });
      });
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

      # API — Rust on oci-apps (default), Flask (/flask/*), Go (/go/*) on gcp-proxy
      api.diegonmarcos.com {
    ${sec}
        @root path /
        handle @root {
          redir https://diegonmarcos.github.io/api/ permanent
        }

        handle /flask/apispec.json {
          uri strip_prefix /flask
          reverse_proxy ${gcp}:5000
        }
        handle_path /flask/* {
          ${mkProtected "${gcp}:5000"}
        }
        handle /go/docs/openapi.json {
          header Access-Control-Allow-Origin "*"
          header Access-Control-Allow-Methods "GET, OPTIONS"
          header Access-Control-Allow-Headers "Content-Type"
          reverse_proxy ${gcp}:8090
        }
        handle /go/* {
          reverse_proxy ${gcp}:8090
        }
        handle /crawlee/openapi.json {
          uri strip_prefix /crawlee
          reverse_proxy ${flex0}:3000
        }
        handle_path /crawlee/* {
          ${mkProtected "${flex0}:3000"}
        }
        handle {
          reverse_proxy ${flex0}:8080
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
        handle_path /crawlee/* {
          ${mkProtected "${flex0}:3001"}
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
