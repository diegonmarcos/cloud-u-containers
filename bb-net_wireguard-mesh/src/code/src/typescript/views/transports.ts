import type { Snapshot } from '../modules/types';
import { escapeHtml } from '../modules/format';

export function renderTransports(host: HTMLElement, snap: Snapshot): void {
  const cards = snap.transports.map(t => `
    <div class="kpi is-${t.protocol}">
      <div class="kpi__label">${escapeHtml(t.label)}</div>
      <div class="kpi__value">${t.active_peers ?? 0}</div>
      <div class="kpi__sub">
        <span class="pill is-${t.protocol}">${t.protocol.toUpperCase()}/${t.port}</span>
        ${t.primary  ? '<span class="pill is-primary">primary</span>'   : ''}
        ${t.fallback ? '<span class="pill is-fallback">fallback</span>' : ''}
      </div>
    </div>
  `).join('');

  const rows = snap.transports.map(t => `
    <tr>
      <td class="t-strong">${escapeHtml(t.name)}</td>
      <td>${escapeHtml(t.label)}</td>
      <td><span class="pill is-${t.protocol}">${t.protocol.toUpperCase()}</span></td>
      <td class="t-mono">${t.port}</td>
      <td class="t-mono">${escapeHtml(t.endpoint)}</td>
      <td>${t.primary  ? '<span class="pill is-primary">✓</span>'  : '<span class="u-muted">—</span>'}</td>
      <td>${t.fallback ? '<span class="pill is-fallback">✓</span>' : '<span class="u-muted">—</span>'}</td>
      <td class="t-mono">${t.active_peers ?? 0}</td>
      <td class="t-muted">${escapeHtml(t.use_case ?? '—')}</td>
    </tr>
  `).join('');

  host.innerHTML = `
    <div class="view">
      <h1 class="t-h1">Transports</h1>
      <p class="t-meta">${snap.transports.length} transport(s) · UDP-direct primary, TCP/443 wstunnel fallback</p>

      <div class="kpi-grid u-mt-4">${cards}</div>

      <div class="section">
        <div class="section__head"><div class="section__title">Detail</div></div>
        <div class="table-wrap">
          <table class="tbl">
            <thead>
              <tr><th>name</th><th>label</th><th>proto</th><th>port</th><th>endpoint</th><th>primary</th><th>fallback</th><th>peers</th><th>use case</th></tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      </div>
    </div>
  `;
}
