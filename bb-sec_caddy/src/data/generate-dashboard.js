#!/usr/bin/env node
// Generates dashboard.html from JSON data files
// Usage: node generate-dashboard.js vms.json services.json security.json firewall.json docker_ports.json dns.json
const fs = require('fs');
const [,, vmsFile, svcFile, secFile, fwFile, dkFile, dnsFile] = process.argv;

const vms = JSON.parse(fs.readFileSync(vmsFile, 'utf8'));
const services = JSON.parse(fs.readFileSync(svcFile, 'utf8'));
const security = JSON.parse(fs.readFileSync(secFile, 'utf8'));
const firewall = JSON.parse(fs.readFileSync(fwFile, 'utf8'));
const dockerPorts = JSON.parse(fs.readFileSync(dkFile, 'utf8'));
const dns = JSON.parse(fs.readFileSync(dnsFile, 'utf8'));

// ── Helper: escape HTML ──
const esc = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');

// ── Table builders ──
function table(headers, rows) {
  let h = '<table><thead><tr>' + headers.map(h => `<th>${h}</th>`).join('') + '</tr></thead><tbody>\n';
  for (const row of rows) {
    h += '<tr>' + row.map(c => `<td>${c}</td>`).join('') + '</tr>\n';
  }
  return h + '</tbody></table>';
}

// ── VM table ──
const vmRows = Object.values(vms).map(v => [
  `<strong>${esc(v.alias)}</strong>`, v.provider, v.tier,
  `<code>${esc(v.ip)}</code>`, `<code>${esc(v.wg)}</code>`,
  v.ram, v.cpu, v.availability
]);

// ── Services table ──
const svcRows = services.map(s => [
  `<code>${esc(s.domain)}</code>`, `<strong>${esc(s.name)}</strong>`,
  esc(s.vm), esc(s.port), esc(s.auth), esc(s.avail)
]);

// ── Security table ──
const secRows = security.map(l => [l.n, `<strong>${esc(l.name)}</strong>`, esc(l.desc)]);

// ── Firewall table ──
const fwRows = firewall.map(r => [
  `<strong>${esc(r.vm)}</strong>`, `<code>${esc(r.ip)}</code>`,
  esc(r.port), esc(r.bind), esc(r.purpose),
  r.status === 'open' ? '<span class="st-ok">OPEN</span>' : '<span class="st-warn">RESTRICT</span>'
]);

// ── Docker ports table ──
const dkRows = dockerPorts.map(d => [
  `<strong>${esc(d.vm)}</strong>`, esc(d.container), esc(d.port),
  `<code>${esc(d.bind)}</code>`, esc(d.internal), esc(d.note)
]);

// ── Declared containers summary (grouped by VM) ──
const grouped = {};
for (const d of dockerPorts) {
  if (!grouped[d.vm]) grouped[d.vm] = new Set();
  grouped[d.vm].add(d.container);
}
const declContRows = Object.keys(grouped).sort().map(vm => {
  const containers = [...grouped[vm]].sort();
  return [`<strong>${esc(vm)}</strong>`, String(containers.length), containers.join(', ')];
});

// ── DNS tables ──
const cfRows = dns.cloudflare.map(r => [
  esc(r.type), `<code>${esc(r.name)}</code>`, `<code>${esc(r.value)}</code>`,
  String(r.ttl), esc(r.purpose)
]);
const hickFwdRows = dns.hickory.forward.map(r => [
  `<code>${esc(r.name)}.internal</code>`, `<code>${esc(r.ip)}</code>`,
  esc(r.vm), esc(r.purpose)
]);
const hickRevRows = dns.hickory.reverse.map(r => [
  `<code>${esc(r.ip)}</code>`, `<code>${esc(r.hostname)}</code>`, esc(r.vm)
]);
const emailRows = dns.email_auth.map(r => [
  esc(r.type), `<code>${esc(r.name)}</code>`, `<code>${esc(r.value)}</code>`, esc(r.purpose)
]);

// ── WireGuard IPs for topology diagram ──
const wgMap = {};
for (const v of Object.values(vms)) wgMap[v.alias] = v.wg;

// ── Assemble HTML ──
process.stdout.write(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Infrastructure Dashboard</title>
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

<h1>Infrastructure Dashboard</h1>
<p><em>proxy.diegonmarcos.com</em> \u2014 generated from JSON data files</p>
<hr>

<div class="tab-bar">
<button class="tab-btn active" data-tab="dns">DNS</button>
<button class="tab-btn" data-tab="proxy">Reverse Proxy</button>
<button class="tab-btn" data-tab="security">Security</button>
<button class="tab-btn" data-tab="containers">Containers</button>
</div>

<!-- ═══ TAB: DNS ═══ -->
<div class="tab-content active" id="tab-dns">

<h2>Public DNS (Cloudflare)</h2>
<p><em>diegonmarcos.com</em> \u2014 all records point to gcp-proxy (35.226.147.64) except smtp/imap direct to oci-mail</p>
${table(['Type','Name','Value','TTL','Purpose'], cfRows)}

<hr>
<h2>Internal DNS (Hickory \u2014 .internal zone)</h2>
<p><em>WireGuard mesh only</em> \u2014 resolved by Hickory DNS on gcp-proxy:53</p>
${table(['Name','IP','VM','Purpose'], hickFwdRows)}

<hr>
<h2>Reverse DNS (PTR)</h2>
${table(['IP','Hostname','VM'], hickRevRows)}

<hr>
<h2>Email Authentication</h2>
${table(['Type','Name','Value','Purpose'], emailRows)}

</div>

<!-- ═══ TAB: Reverse Proxy ═══ -->
<div class="tab-content" id="tab-proxy">

<h2>Reverse Proxying</h2>
<button class="rbtn" id="toggle-svcs">Show Live</button>
<div id="live-svcs" class="tier-body" style="display:none"></div>
${table(['Domain','Service','VM','Port','Auth','Availability'], svcRows)}

<hr>
<h2>Auth Flow</h2>
<pre><code>Browser Request
    \u2502
    \u25bc
\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502  Cloudflare  \u2502  DNS only (grey cloud, no proxy)
\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2518
       \u2502
       \u25bc
\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502    Caddy     \u2502  TLS termination, security headers,
\u2502  (gcp-proxy) \u2502  rate limiting, bot/scanner blocking
\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2518
       \u2502
   \u250c\u2500\u2500\u2500\u2534\u2500\u2500\u2500\u2510
   \u2502       \u2502
Bearer?  Cookie?
   \u2502       \u2502
   \u25bc       \u25bc
\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2510 \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502intro-\u2502 \u2502 Authelia  \u2502  TOTP / WebAuthn
\u2502spect \u2502 \u2502   2FA    \u2502
\u2514\u2500\u2500\u252c\u2500\u2500\u2500\u2518 \u2514\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2518
   \u2502          \u2502
   \u2514\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2518
        \u2502
        \u25bc
\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502  WireGuard   \u2502  Encrypted mesh to target VM
\u2502   tunnel     \u2502
\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2518
       \u2502
       \u25bc
  [ Service ]</code></pre>

<hr>
<h2>Network Topology</h2>
<pre><code>Internet
    \u2502
    \u25bc
\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502  Cloudflare  (*.diegonmarcos.com) DNS only   \u2502
\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518
                   \u2502
                   \u25bc
\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502  gcp-proxy  ${wgMap['gcp-proxy']||''}                           \u2502
\u2502  \u251c\u2500 Caddy (reverse proxy + TLS)              \u2502
\u2502  \u251c\u2500 Authelia (2FA) + introspect-proxy        \u2502
\u2502  \u251c\u2500 Flask API + Go API                       \u2502
\u2502  \u251c\u2500 Vaultwarden, ntfy, Dozzle               \u2502
\u2502  \u2514\u2500 Sauron Central + Syslog Central          \u2502
\u2514\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518
     \u2502 wg0      \u2502 wg0      \u2502 wg0  \u2502 wg0       \u2502 wg0
     \u25bc          \u25bc          \u25bc      \u25bc           \u25bc
\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510 \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510 \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510 \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502oci-apps  \u2502 \u2502oci-apps-1\u2502 \u2502oci-mail \u2502 \u2502oci-analyti.\u2502
\u2502 ${wgMap['oci-apps']||''} \u2502 \u2502 ${wgMap['oci-apps-1']||''}  \u2502 \u2502 ${wgMap['oci-mail']||''} \u2502 \u2502${wgMap['oci-analytics']||''}\u2502
\u2502          \u2502 \u2502          \u2502 \u2502         \u2502 \u2502            \u2502
\u2502Rust API  \u2502 \u2502PhotoPrism\u2502 \u2502 Mailu   \u2502 \u2502  Matomo    \u2502
\u2502Crawlee   \u2502 \u2502 NocoDB   \u2502 \u2502Syncthing\u2502 \u2502  Windmill  \u2502
\u2502Quant Lab \u2502 \u2502Code Srv  \u2502 \u2502Radicale \u2502 \u2502            \u2502
\u2502          \u2502 \u2502 AFFiNE   \u2502 \u2502         \u2502 \u2502            \u2502
\u2502          \u2502 \u2502Grist,LGTM\u2502 \u2502         \u2502 \u2502            \u2502
\u2502          \u2502 \u2502Gitea,Ethr\u2502 \u2502         \u2502 \u2502            \u2502
\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518 \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518 \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518 \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518

\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510 \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
\u2502oci-apps-2\u2502 \u2502gcp-ollama\u2502
\u2502 ${wgMap['oci-apps-2']||''} \u2502 \u2502 ${wgMap['gcp-ollama']||''}   \u2502
\u2502          \u2502 \u2502          \u2502
\u2502(on-demand\u2502 \u2502 Ollama   \u2502
\u2502 compute) \u2502 \u2502 LLM      \u2502
\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518 \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518</code></pre>

</div>

<!-- ═══ TAB: Security ═══ -->
<div class="tab-content" id="tab-security">

<h2>Security Stack</h2>
${table(['Layer','Name','Description'], secRows)}

<hr>
<h2>Firewall &amp; Ports</h2>
<p>Only <strong>gcp-proxy</strong> accepts public HTTP/HTTPS traffic. All other VMs restrict to WireGuard mesh + service-specific ports.</p>
${table(['VM','WG IP','Port','Bind','Purpose','Status'], fwRows)}
<p><strong>Policy</strong>: All VMs run <code>51820/udp</code> (WireGuard) + <code>22/tcp</code> (SSH restricted). gcp-proxy additionally exposes <code>80/443</code> (Caddy). oci-mail exposes <code>25,465,587,993</code> (mail delivery).</p>

<h3>iptables / nftables</h3>
${table(['Chain','Policy','Notes'], [
  ['INPUT','DROP (cloud firewall)','Only allowed ports above reach the VM'],
  ['FORWARD','ACCEPT (Docker)','Docker manages container routing via nftables'],
  ['OUTPUT','ACCEPT','No egress filtering'],
  ['DOCKER-USER','ACCEPT','Default \u2014 no extra restrictions'],
  ['wg0','All traffic','Mesh peers trusted, no per-port filtering'],
])}

<hr>
<h2>Docker Network</h2>
<button class="rbtn" id="toggle-docker">Show Live</button>
<div id="live-docker" class="tier-body" style="display:none"></div>
${table(['VM','Container','Host Port','Bind Address','Internal','Note'], dkRows)}

</div>

<!-- ═══ TAB: Containers ═══ -->
<div class="tab-content" id="tab-containers">

<h2>Virtual Machines</h2>
<button class="rbtn" id="toggle-vms">Show Live</button>
<div id="live-vms" class="tier-body" style="display:none"></div>
${table(['Alias','Provider','Tier','Public IP','WG IP','RAM','CPU','Availability'], vmRows)}

<hr>
<h2>Declared Containers</h2>
${table(['VM','Count','Containers'], declContRows)}

<hr>
<div id="health-section">
<h2>Live Health</h2>
<p>Lazy-loaded from <code>/api/health/*</code> and <code>/api/profiling/*</code>. Click <em>Refresh</em> to load each tier.</p>

<div class="health-tier">
<div class="tier-hdr"><h3>Declared <span class="tier-lbl">Tier 0 \u2014 Config (instant)</span></h3><button class="rbtn" id="btn-declared">Refresh</button></div>
<div class="tier-body" id="out-declared">\u2014</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Deployed <span class="tier-lbl">Tier 1 \u2014 docker ps (~3s)</span></h3><button class="rbtn" id="btn-deployed">Refresh</button></div>
<div class="tier-body" id="out-deployed">\u2014</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Drift <span class="tier-lbl">Tier 2 \u2014 Declared vs Deployed (~3s)</span></h3><button class="rbtn" id="btn-drift">Refresh</button></div>
<div class="tier-body" id="out-drift">\u2014</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Status <span class="tier-lbl">Tier 3 \u2014 Comprehensive (heavy)</span></h3><button class="rbtn warn" id="btn-status">Refresh</button></div>
<div class="tier-body" id="out-status">\u2014</div>
</div>

<div class="health-tier">
<div class="tier-hdr"><h3>Profiling <span class="tier-lbl">Tier 4 \u2014 Deep Diagnostic (heaviest)</span></h3></div>
<div class="tier-body" id="out-profiling">Load <em>Declared</em> first, then trigger per-container.</div>
</div>
</div>

</div>

<hr>
<p><code>visitor@caddy:~$</code> <a href="https://linktree.diegonmarcos.com">cd /home</a></p>

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
  var h='';
  var vms=d.vms||{};
  for(var id in vms){
    var v=vms[id],cs=v.containers||[];
    h+='<div class="health-tier" style="margin:.5rem 0;padding:.5rem .75rem;border-color:#1a1a2e">';
    h+='<strong>'+id+'</strong> ('+(v.label||"")+') \u2014 ';
    h+='<span class="st-ok">'+v.running+' running</span>, ';
    h+='<span class="'+(v.stopped>0?'st-warn':'st-off')+'">'+v.stopped+' stopped</span>';
    if(cs.length>0){
      h+='<table style="margin:.4rem 0"><tr><th>Container</th><th>State</th><th>Ports</th></tr>';
      for(var i=0;i<cs.length;i++){
        var c=cs[i],cls=c.state==='running'?'st-ok':(c.state==='exited'?'st-err':'st-warn');
        h+='<tr><td>'+c.name+'</td><td class="'+cls+'">'+c.state+'</td><td>'+(c.ports||'\u2014')+'</td></tr>';
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
    var stMap={};for(var k=0;k<dcs.length;k++)stMap[dcs[k].name]={state:dcs[k].state,ports:dcs[k].ports||''};
    var unhealthy=[];
    for(var j=0;j<cs.length;j++){var si=stMap[cs[j]];if(!si||si.state!=='running')unhealthy.push(cs[j])}
    h+='<div class="prof-vm"><strong>'+id+'</strong> ('+(v.label||"")+') \u2014 '+cs.length+' containers ';
    h+='<button class="prof-btn warn" data-profvm="'+id+'">Profile All</button> ';
    if(unhealthy.length>0)h+='<button class="prof-btn warn" data-profbad="'+id+'">Profile '+unhealthy.length+' Unhealthy</button>';
    h+='</div>';
    h+='<div id="profvm-'+id+'"></div>';
    h+='<table><tr><th>Container</th><th>State</th><th>Ports</th><th>Action</th><th>Result</th></tr>';
    for(var j=0;j<cs.length;j++){
      var cn=cs[j],si=stMap[cn];
      var st=si?si.state:'not deployed',pts=si?si.ports:'';
      var cls=st==='running'?'st-ok':(st==='exited'||st==='not deployed'?'st-err':'st-warn');
      h+='<tr><td>'+cn+'</td><td class="'+cls+'">'+st+'</td><td>'+(pts||'\u2014')+'</td>';
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
            var h='';for(var r=0;r<results.length;r++){var ri=results[r];h+='<span class="'+ri.cls+'">'+ri.name+': '+ri.status+'</span><br>'}
            el.className='';el.innerHTML=h;
          }
        });
    })(bad[j]);
  }
}
// Toggle: Declared (static) <-> Live (API)
function setupToggle(btnId, liveId, fetchFn) {
  var btn = document.getElementById(btnId);
  if (!btn) return;
  var liveEl = document.getElementById(liveId);
  var staticEl = liveEl.nextElementSibling;
  var loaded = false;
  btn.addEventListener('click', function() {
    if (liveEl.style.display === 'none') {
      if (staticEl) staticEl.style.display = 'none';
      liveEl.style.display = '';
      btn.textContent = 'Show Declared';
      if (!loaded) { loaded = true; fetchFn(liveEl); }
    } else {
      if (staticEl) staticEl.style.display = '';
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
        h += '<tr><td>' + id + '</td><td><strong>' + (v.label || '') + '</strong></td><td>' + sc + '</td><td>' + cc + '</td></tr>';
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
          var cs = svcs[sn], dom = '';
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
      var dvms = d.vms || {}, h = '';
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
`);
