"use strict";(()=>{var V={route:{path:"overview",params:{}},snapshot:null},f=class{constructor(){this.state={...V};this.listeners=new Set}get(){return this.state}set(t){this.state={...this.state,...t},this.listeners.forEach(s=>s())}subscribe(t){return this.listeners.add(t),()=>{this.listeners.delete(t)}}},v=new f;function x(){let e=globalThis.PORTAL_DATA;if(!e||!("mesh"in e))throw new Error('PORTAL_DATA["mesh"] not found. Ensure data-mesh.json.js is loaded BEFORE script.js.');return e.mesh}function G(e){let t=e.replace(/^#\/?/,""),[s,a]=t.split("?"),o={};return a&&a.split("&").forEach(r=>{let[l,p]=r.split("=");l&&(o[decodeURIComponent(l)]=decodeURIComponent(p??""))}),{path:s||"",params:o}}function M(e,t={}){let s=Object.entries(t).map(([a,o])=>`${encodeURIComponent(a)}=${encodeURIComponent(o)}`).join("&");location.hash=`#/${e}${s?"?"+s:""}`}function S(e){let t=()=>{let s=G(location.hash);s.path||(s={path:"overview",params:{}}),e(s)};window.addEventListener("hashchange",t),t()}var T={overview:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',topology:'<circle cx="12" cy="5" r="2"/><circle cx="5" cy="19" r="2"/><circle cx="19" cy="19" r="2"/><path d="M12 7v3M12 14l-7 5M12 14l7 5"/>',nodes:'<rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><circle cx="7" cy="7" r="1" fill="currentColor"/><circle cx="7" cy="17" r="1" fill="currentColor"/>',peers:'<circle cx="9" cy="8" r="3"/><circle cx="17" cy="11" r="2.5"/><path d="M3 21c0-3 3-6 6-6s6 3 6 6"/><path d="M14 19c0-2 1.5-4 3-4s3 2 3 4"/>',transports:'<path d="M3 12h18"/><path d="M7 8l-4 4 4 4"/><path d="M17 8l4 4-4 4"/>',routes:'<path d="M5 12h4l2-3 4 6 2-3h2"/><circle cx="5" cy="12" r="1.6" fill="currentColor"/><circle cx="19" cy="12" r="1.6" fill="currentColor"/>',health:'<path d="M12 21s-7-4.5-9.5-9A4.8 4.8 0 0 1 7 5c2 0 3.5 1.5 5 3 1.5-1.5 3-3 5-3a4.8 4.8 0 0 1 4.5 7C19 16.5 12 21 12 21Z"/>',shield:'<path d="M12 3 4 6v6c0 5 3.5 8.5 8 9 4.5-.5 8-4 8-9V6l-8-3Z"/>',lock:'<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',refresh:'<path d="M21 12a9 9 0 0 1-15.5 6.3L3 16"/><path d="M3 12a9 9 0 0 1 15.5-6.3L21 8"/><path d="M3 4v4h4"/><path d="M21 20v-4h-4"/>',external:'<path d="M14 4h6v6"/><path d="M10 14 20 4"/><path d="M19 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5"/>'};function $(e,t=18){let s=T[e]??T.shield;return`<svg viewBox="0 0 24 24" width="${t}" height="${t}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${s}</svg>`}function i(e){return String(e??"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#39;")}function u(e){if(!e)return"\u2014";let t=new Date(e);return Number.isNaN(t.getTime())?e:t.toLocaleString("en-GB",{dateStyle:"medium",timeStyle:"short"})}function H(e){if(!e)return"\u2014";let t=new Date(e);if(Number.isNaN(t.getTime()))return e;let s=Math.max(0,Math.floor((Date.now()-t.getTime())/1e3));return s<60?s+"s ago":s<3600?Math.floor(s/60)+"m ago":s<86400?Math.floor(s/3600)+"h ago":Math.floor(s/86400)+"d ago"}function P(e,t=86400){if(!e)return!0;let s=new Date(e);return Number.isNaN(s.getTime())?!0:(Date.now()-s.getTime())/1e3>t}function L(e){return{"us-central1":"\u{1F1FA}\u{1F1F8}","eu-marseille-1":"\u{1F1EB}\u{1F1F7}",roaming:"\u{1F30D}"}[e]??"\u{1F3F3}"}var F=[{id:"A",label:"Mesh",items:[{id:"A0",route:"overview",label:"Overview",icon:"overview"},{id:"A1",route:"topology",label:"Topology",icon:"topology"},{id:"A2",route:"nodes",label:"Nodes",icon:"nodes"},{id:"A3",route:"peers",label:"Peers",icon:"peers"}]},{id:"B",label:"Transport",items:[{id:"B0",route:"transports",label:"Transports",icon:"transports"},{id:"B1",route:"routes",label:"Routes",icon:"routes"}]},{id:"C",label:"State",items:[{id:"C0",route:"health",label:"Health",icon:"health"}]}];function R(e){e.innerHTML=`
    <div class="app">
      <div class="app__brand">
        <div class="brand-mark"><span>WG</span></div>
        <div class="brand-name">
          <span class="brand-name__word">Wireguard Mesh</span>
          <span class="brand-name__tag">Read-only</span>
        </div>
      </div>
      <header class="app__topbar topbar" id="topbar"></header>
      <nav class="app__nav sidebar" id="sidebar"></nav>
      <main class="app__main" id="main"></main>
    </div>
  `}function E(e){let t=document.getElementById("topbar");if(!t)return;let s=P(e.health.last_snapshot_at);t.innerHTML=`
    <div class="topbar__title">
      <div class="topbar__title__heading">${e.nodes.length} nodes \xB7 ${e.peers.length} peers \xB7 ${e.transports.length} transports</div>
      <div class="topbar__title__sub">schema ${e._meta.schema} \xB7 ${e._meta.generated_by}</div>
    </div>
    <div class="topbar__spacer"></div>
    <div class="topbar__group">
      <div class="snapshot-pill ${s?"is-stale":""}" title="Snapshot generated at ${e._meta.generated_at}">
        <span class="snapshot-pill__dot"></span>
        <span class="snapshot-pill__label">${s?"STALE":"FRESH"}</span>
        <span class="snapshot-pill__age">${H(e.health.last_snapshot_at)}</span>
      </div>
      <button class="icon-btn" aria-label="Read-only \xB7 view source" title="Read-only \xB7 view source">${$("lock")}</button>
    </div>
  `}function A(e){let t=document.getElementById("sidebar");if(!t)return;let s=F.map(a=>`
    <div class="nav-section">
      <header class="nav-section__head">
        <span class="nav-section__id">${a.id}</span>
        <span class="nav-section__label">${a.label}</span>
      </header>
      <div class="nav-section__items">
        ${a.items.map(o=>`
          <a class="nav-link ${o.route===e?"is-active":""}" data-route="${o.route}">
            <span class="nav-link__icon">${$(o.icon)}</span>
            <span class="nav-link__label">${o.label}</span>
          </a>
        `).join("")}
      </div>
    </div>
  `).join("");t.innerHTML=`
    ${s}
    <hr class="nav-divider"/>
    <div class="nav-footer">
      Read-only panel. State lives in cloud-data; this view never mutates.
    </div>
  `,t.addEventListener("click",a=>{let o=a.target.closest("[data-route]");o&&(M(o.dataset.route),v.set({}))})}function C(e,t){let s=t.nodes.filter(d=>d.role==="hub").length,a=t.nodes.filter(d=>d.role==="spoke").length,o=t.nodes.filter(d=>d.role==="client").length,r=t.transports.find(d=>d.protocol==="udp"),l=t.transports.find(d=>d.protocol==="tcp"),p=t.nodes.filter(d=>d.wstunnel_client).length;e.innerHTML=`
    <div class="view">
      <h1 class="t-h1">Mesh overview</h1>
      <p class="t-meta">${t.nodes.length} nodes \xB7 ${t.peers.length} peer-edges \xB7 last sync ${u(t.health.last_snapshot_at)}</p>

      <div class="kpi-grid u-mt-4">
        <div class="kpi is-hub">
          <div class="kpi__label">Hubs</div>
          <div class="kpi__value">${s}</div>
          <div class="kpi__sub">terminate UDP + TCP/443</div>
        </div>
        <div class="kpi is-spoke">
          <div class="kpi__label">Spokes (VMs)</div>
          <div class="kpi__value">${a}</div>
          <div class="kpi__sub">cloud VMs on the mesh</div>
        </div>
        <div class="kpi is-client">
          <div class="kpi__label">Clients</div>
          <div class="kpi__value">${o}</div>
          <div class="kpi__sub">${p} with wstunnel fallback</div>
        </div>
        <div class="kpi is-udp">
          <div class="kpi__label">UDP transport</div>
          <div class="kpi__value">${r?.active_peers??0}</div>
          <div class="kpi__sub">${i(r?.endpoint??"\u2014")}</div>
        </div>
        <div class="kpi is-tcp">
          <div class="kpi__label">TCP/443 fallback</div>
          <div class="kpi__value">${l?.active_peers??0}</div>
          <div class="kpi__sub">${i(l?.endpoint??"\u2014")}</div>
        </div>
        <div class="kpi">
          <div class="kpi__label">Health</div>
          <div class="kpi__value">${i(t.health.status)}</div>
          <div class="kpi__sub">${t.health.tls_expiries.length} cert(s) tracked</div>
        </div>
      </div>

      <div class="section">
        <div class="section__head">
          <div class="section__title">Snapshot metadata</div>
        </div>
        <div class="table-wrap">
          <table class="tbl">
            <tbody>
              <tr><td class="t-label" style="width:200px">schema</td><td class="t-mono">${i(t._meta.schema)}</td></tr>
              <tr><td class="t-label">generated_by</td><td class="t-mono">${i(t._meta.generated_by)}</td></tr>
              <tr><td class="t-label">generated_at</td><td class="t-mono">${i(t._meta.generated_at)}</td></tr>
              <tr><td class="t-label">last_snapshot_at</td><td class="t-mono">${i(t.health.last_snapshot_at)}</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  `}function q(e){let t=new Map,s=800,a=460,o=s/2,r=a/2,l=e.find(m=>m.role==="hub");l&&t.set(l.name,{x:o,y:r});let p=e.filter(m=>m.role!=="hub"),d=Math.min(s,a)*.36;return p.forEach((m,n)=>{let c=n/Math.max(1,p.length)*Math.PI*2-Math.PI/2;t.set(m.name,{x:o+d*Math.cos(c),y:r+d*Math.sin(c)})}),t}function Z(e,t,s){return t?.wstunnel_client||s?.wstunnel_client?"tcp":"udp"}function N(e,t){let o=q(t.nodes),r=new Map(t.nodes.map(n=>[n.name,n])),l=new Set,p=[];for(let n of t.peers){let c=n.from,h=n.to,y=c<h?`${c}|${h}`:`${h}|${c}`;if(l.has(y))continue;l.add(y);let g=r.get(c),b=r.get(h),w=o.get(c),k=o.get(h);!g||!b||!w||!k||p.push({from:g,to:b,fromPos:w,toPos:k,kind:Z(n,g,b)})}let d=p.map(n=>`
    <line class="topo-edge is-${n.kind}" x1="${n.fromPos.x}" y1="${n.fromPos.y}" x2="${n.toPos.x}" y2="${n.toPos.y}">
      <title>${i(n.from.name)} \u2194 ${i(n.to.name)} \xB7 ${n.kind.toUpperCase()}</title>
    </line>
  `).join(""),m=t.nodes.map(n=>{let c=o.get(n.name);if(!c)return"";let h=n.role==="hub"?26:20;return`
      <g class="topo-node" transform="translate(${c.x},${c.y})">
        <title>${i(n.name)} (${i(n.role)}) \xB7 ${i(n.public_ip)} \u2192 ${i(n.wg_ip)}</title>
        <circle class="topo-node__circle is-${n.role}" r="${h}" />
        <text class="topo-node__label" y="${h+14}">${i(n.name)}</text>
        <text class="topo-node__sublabel" y="${h+28}">${i(n.wg_ip)}</text>
      </g>
    `}).join("");e.innerHTML=`
    <div class="view">
      <h1 class="t-h1">Topology</h1>
      <p class="t-meta">Hub-and-spoke \xB7 ${p.length} edges \xB7 transport-colored</p>

      <div class="topology u-mt-4">
        <header class="topology__head">
          <div class="section__title">${t.nodes.length} nodes</div>
          <div class="topology__legend">
            <span class="topology__legend-item is-hub"><span class="topology__legend-item__swatch"></span>Hub</span>
            <span class="topology__legend-item is-spoke"><span class="topology__legend-item__swatch"></span>Spoke</span>
            <span class="topology__legend-item is-client"><span class="topology__legend-item__swatch"></span>Client</span>
            <span class="topology__legend-item is-udp"><span class="topology__legend-item__swatch"></span>UDP</span>
            <span class="topology__legend-item is-tcp"><span class="topology__legend-item__swatch"></span>TCP/443</span>
          </div>
        </header>
        <svg class="topology__svg" viewBox="0 0 800 460" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="WireGuard mesh topology">
          ${d}
          ${m}
        </svg>
      </div>
    </div>
  `}function j(e,t){let s=t.nodes.map(a=>`
    <tr>
      <td class="t-strong">${i(a.name)}</td>
      <td><span class="pill is-${i(a.role)}">${i(a.role)}</span></td>
      <td class="t-mono">${i(a.public_ip)}</td>
      <td class="t-mono">${i(a.wg_ip)}</td>
      <td>${L(a.region)} ${i(a.region)}</td>
      <td class="t-muted">${i(a.provider)}</td>
      <td class="t-muted">${i(a.os)}</td>
      <td class="t-mono t-muted">${i(a.public_key_fp??"\u2014")}</td>
      <td class="t-mono">${(a.ports_public??[]).join(" \xB7 ")||'<span class="u-muted">none</span>'}</td>
    </tr>
  `).join("");e.innerHTML=`
    <div class="view">
      <h1 class="t-h1">Nodes</h1>
      <p class="t-meta">${t.nodes.length} nodes registered in cloud-data-topology</p>

      <div class="table-wrap u-mt-4">
        <table class="tbl">
          <thead>
            <tr>
              <th>name</th><th>role</th><th>public IP</th><th>WG IP</th>
              <th>region</th><th>provider</th><th>OS</th><th>pubkey</th><th>public ports</th>
            </tr>
          </thead>
          <tbody>${s}</tbody>
        </table>
      </div>
    </div>
  `}function I(e,t){let s=new Map;for(let o of t.peers)s.has(o.from)||s.set(o.from,[]),s.get(o.from).push(o);let a=[...s.entries()].map(([o,r])=>`
    <div class="section">
      <div class="section__head">
        <div class="section__title">${i(o)}</div>
        <div class="section__count">${r.length} peer${r.length===1?"":"s"}</div>
      </div>
      <div class="table-wrap">
        <table class="tbl">
          <thead><tr><th>to</th><th>AllowedIPs</th><th>keepalive</th></tr></thead>
          <tbody>
            ${r.map(l=>`
              <tr>
                <td class="t-strong">${i(l.to)}</td>
                <td class="t-mono">${l.allowed_ips.map(p=>i(p)).join(", ")}</td>
                <td class="t-mono">${l.persistent_keepalive}s</td>
              </tr>
            `).join("")}
          </tbody>
        </table>
      </div>
    </div>
  `).join("");e.innerHTML=`
    <div class="view">
      <h1 class="t-h1">Peers</h1>
      <p class="t-meta">${t.peers.length} peer relationships across ${s.size} nodes</p>
      ${a}
    </div>
  `}function D(e,t){let s=t.transports.map(o=>`
    <div class="kpi is-${o.protocol}">
      <div class="kpi__label">${i(o.label)}</div>
      <div class="kpi__value">${o.active_peers??0}</div>
      <div class="kpi__sub">
        <span class="pill is-${o.protocol}">${o.protocol.toUpperCase()}/${o.port}</span>
        ${o.primary?'<span class="pill is-primary">primary</span>':""}
        ${o.fallback?'<span class="pill is-fallback">fallback</span>':""}
      </div>
    </div>
  `).join(""),a=t.transports.map(o=>`
    <tr>
      <td class="t-strong">${i(o.name)}</td>
      <td>${i(o.label)}</td>
      <td><span class="pill is-${o.protocol}">${o.protocol.toUpperCase()}</span></td>
      <td class="t-mono">${o.port}</td>
      <td class="t-mono">${i(o.endpoint)}</td>
      <td>${o.primary?'<span class="pill is-primary">\u2713</span>':'<span class="u-muted">\u2014</span>'}</td>
      <td>${o.fallback?'<span class="pill is-fallback">\u2713</span>':'<span class="u-muted">\u2014</span>'}</td>
      <td class="t-mono">${o.active_peers??0}</td>
      <td class="t-muted">${i(o.use_case??"\u2014")}</td>
    </tr>
  `).join("");e.innerHTML=`
    <div class="view">
      <h1 class="t-h1">Transports</h1>
      <p class="t-meta">${t.transports.length} transport(s) \xB7 UDP-direct primary, TCP/443 wstunnel fallback</p>

      <div class="kpi-grid u-mt-4">${s}</div>

      <div class="section">
        <div class="section__head"><div class="section__title">Detail</div></div>
        <div class="table-wrap">
          <table class="tbl">
            <thead>
              <tr><th>name</th><th>label</th><th>proto</th><th>port</th><th>endpoint</th><th>primary</th><th>fallback</th><th>peers</th><th>use case</th></tr>
            </thead>
            <tbody>${a}</tbody>
          </table>
        </div>
      </div>
    </div>
  `}function B(e,t){let s=t.routes.map(a=>{let r=t.transports.find(l=>l.name===a.via_transport)?.protocol??"udp";return`
      <tr>
        <td class="t-strong">${i(a.src_node)}</td>
        <td class="t-mono">${i(a.dst_subnet)}</td>
        <td><span class="pill is-${r}">${i(a.via_transport)}</span></td>
        <td class="t-muted">${i(a.comment??"")}</td>
      </tr>
    `}).join("");e.innerHTML=`
    <div class="view">
      <h1 class="t-h1">Routes</h1>
      <p class="t-meta">${t.routes.length} route(s) \xB7 derived from peer AllowedIPs + transport bindings</p>

      <div class="table-wrap u-mt-4">
        <table class="tbl">
          <thead><tr><th>src node</th><th>dst subnet</th><th>via transport</th><th>comment</th></tr></thead>
          <tbody>${s}</tbody>
        </table>
      </div>
    </div>
  `}function U(e,t){let s=t.health.tls_expiries.map(a=>{let o=new Date(a.expires_at),r=Math.floor((o.getTime()-Date.now())/(1e3*60*60*24)),l=r<7||r<30?"is-fallback":"is-primary";return`
      <tr>
        <td class="t-strong">${i(a.host)}</td>
        <td class="t-mono">${u(a.expires_at)}</td>
        <td><span class="pill ${l}">${r}d</span></td>
        <td class="t-muted">${i(a.issuer??"\u2014")}</td>
      </tr>
    `}).join("");e.innerHTML=`
    <div class="view">
      <h1 class="t-h1">Health</h1>
      <p class="t-meta">Status: <span class="pill is-${t.health.status==="healthy"?"primary":"fallback"}">${i(t.health.status)}</span> \xB7 last snapshot ${u(t.health.last_snapshot_at)}</p>

      <div class="section u-mt-4">
        <div class="section__head"><div class="section__title">TLS expiries</div><div class="section__count">${t.health.tls_expiries.length}</div></div>
        <div class="table-wrap">
          <table class="tbl">
            <thead><tr><th>host</th><th>expires_at</th><th>days left</th><th>issuer</th></tr></thead>
            <tbody>${s}</tbody>
          </table>
        </div>
      </div>
    </div>
  `}var _="[wg-mesh]";console.info(_,"script.js evaluated",{ts:Date.now(),readyState:document.readyState});var O={overview:C,topology:N,nodes:j,peers:I,transports:D,routes:B,health:U};function K(){console.info(_,"bootstrap");let e=document.getElementById("app");if(!e){console.error(_,"no #app");return}R(e);let t;try{t=x(),console.info(_,"snapshot loaded",{nodes:t.nodes.length,peers:t.peers.length,transports:t.transports.length,schema:t._meta.schema})}catch(s){let a=document.getElementById("main");a&&(a.innerHTML=`<div class="view"><h1 class="t-h1">Snapshot missing</h1><p class="t-meta">${s.message}</p></div>`);return}v.set({snapshot:t}),v.subscribe(()=>W(t)),S(s=>{v.set({route:s})}),W(t)}function W(e){let{route:t}=v.get();E(e),A(t.path);let s=document.getElementById("main");if(!s)return;let a=O[t.path]??O.overview;try{a(s,e)}catch(o){s.innerHTML=`<div class="view"><h1 class="t-h1">Render error</h1><p class="t-meta">${o.message}</p></div>`}}K();})();
