import type { Snapshot } from '../modules/types';
import { escapeHtml, fmtTimestamp } from '../modules/format';

export function renderHealth(host: HTMLElement, snap: Snapshot): void {
  const tlsRows = snap.health.tls_expiries.map(e => {
    const d = new Date(e.expires_at);
    const daysLeft = Math.floor((d.getTime() - Date.now()) / (1000 * 60 * 60 * 24));
    const cls = daysLeft < 7 ? 'is-fallback' : daysLeft < 30 ? 'is-fallback' : 'is-primary';
    return `
      <tr>
        <td class="t-strong">${escapeHtml(e.host)}</td>
        <td class="t-mono">${fmtTimestamp(e.expires_at)}</td>
        <td><span class="pill ${cls}">${daysLeft}d</span></td>
        <td class="t-muted">${escapeHtml(e.issuer ?? '—')}</td>
      </tr>
    `;
  }).join('');

  host.innerHTML = `
    <div class="view">
      <h1 class="t-h1">Health</h1>
      <p class="t-meta">Status: <span class="pill is-${snap.health.status === 'healthy' ? 'primary' : 'fallback'}">${escapeHtml(snap.health.status)}</span> · last snapshot ${fmtTimestamp(snap.health.last_snapshot_at)}</p>

      <div class="section u-mt-4">
        <div class="section__head"><div class="section__title">TLS expiries</div><div class="section__count">${snap.health.tls_expiries.length}</div></div>
        <div class="table-wrap">
          <table class="tbl">
            <thead><tr><th>host</th><th>expires_at</th><th>days left</th><th>issuer</th></tr></thead>
            <tbody>${tlsRows}</tbody>
          </table>
        </div>
      </div>
    </div>
  `;
}
