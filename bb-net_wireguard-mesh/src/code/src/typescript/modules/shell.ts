import type { Snapshot } from './types';
import { store } from './state';
import { navigate } from './router';
import { svgIcon } from './icons';
import { fmtAge, isStale } from './format';

const NAV = [
  { id: 'A', label: 'Mesh', items: [
    { id: 'A0', route: 'overview',   label: 'Overview',   icon: 'overview' },
    { id: 'A1', route: 'topology',   label: 'Topology',   icon: 'topology' },
    { id: 'A2', route: 'nodes',      label: 'Nodes',      icon: 'nodes' },
    { id: 'A3', route: 'peers',      label: 'Peers',      icon: 'peers' },
  ]},
  { id: 'B', label: 'Transport', items: [
    { id: 'B0', route: 'transports', label: 'Transports', icon: 'transports' },
    { id: 'B1', route: 'routes',     label: 'Routes',     icon: 'routes' },
  ]},
  { id: 'C', label: 'State', items: [
    { id: 'C0', route: 'health',     label: 'Health',     icon: 'health' },
  ]},
];

export function renderShell(host: HTMLElement): void {
  host.innerHTML = `
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
  `;
}

export function renderTopbar(snap: Snapshot): void {
  const el = document.getElementById('topbar'); if (!el) return;
  const stale = isStale(snap.health.last_snapshot_at);
  el.innerHTML = `
    <div class="topbar__title">
      <div class="topbar__title__heading">${snap.nodes.length} nodes · ${snap.peers.length} peers · ${snap.transports.length} transports</div>
      <div class="topbar__title__sub">schema ${snap._meta.schema} · ${snap._meta.generated_by}</div>
    </div>
    <div class="topbar__spacer"></div>
    <div class="topbar__group">
      <div class="snapshot-pill ${stale ? 'is-stale' : ''}" title="Snapshot generated at ${snap._meta.generated_at}">
        <span class="snapshot-pill__dot"></span>
        <span class="snapshot-pill__label">${stale ? 'STALE' : 'FRESH'}</span>
        <span class="snapshot-pill__age">${fmtAge(snap.health.last_snapshot_at)}</span>
      </div>
      <button class="icon-btn" aria-label="Read-only · view source" title="Read-only · view source">${svgIcon('lock')}</button>
    </div>
  `;
}

export function renderSidebar(currentPath: string): void {
  const el = document.getElementById('sidebar'); if (!el) return;
  const sectionsHtml = NAV.map(s => `
    <div class="nav-section">
      <header class="nav-section__head">
        <span class="nav-section__id">${s.id}</span>
        <span class="nav-section__label">${s.label}</span>
      </header>
      <div class="nav-section__items">
        ${s.items.map(it => `
          <a class="nav-link ${it.route === currentPath ? 'is-active' : ''}" data-route="${it.route}">
            <span class="nav-link__icon">${svgIcon(it.icon)}</span>
            <span class="nav-link__label">${it.label}</span>
          </a>
        `).join('')}
      </div>
    </div>
  `).join('');
  el.innerHTML = `
    ${sectionsHtml}
    <hr class="nav-divider"/>
    <div class="nav-footer">
      Read-only panel. State lives in cloud-data; this view never mutates.
    </div>
  `;
  el.addEventListener('click', e => {
    const link = (e.target as HTMLElement).closest('[data-route]') as HTMLElement | null;
    if (link) { navigate(link.dataset.route!); store.set({}); }
  });
}
