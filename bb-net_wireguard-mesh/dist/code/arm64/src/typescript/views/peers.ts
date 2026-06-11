import type { Snapshot } from '../modules/types';
import { escapeHtml } from '../modules/format';

export function renderPeers(host: HTMLElement, snap: Snapshot): void {
  const grouped = new Map<string, typeof snap.peers>();
  for (const p of snap.peers) {
    if (!grouped.has(p.from)) grouped.set(p.from, []);
    grouped.get(p.from)!.push(p);
  }
  const sections = [...grouped.entries()].map(([from, peers]) => `
    <div class="section">
      <div class="section__head">
        <div class="section__title">${escapeHtml(from)}</div>
        <div class="section__count">${peers.length} peer${peers.length === 1 ? '' : 's'}</div>
      </div>
      <div class="table-wrap">
        <table class="tbl">
          <thead><tr><th>to</th><th>AllowedIPs</th><th>keepalive</th></tr></thead>
          <tbody>
            ${peers.map(p => `
              <tr>
                <td class="t-strong">${escapeHtml(p.to)}</td>
                <td class="t-mono">${p.allowed_ips.map(a => escapeHtml(a)).join(', ')}</td>
                <td class="t-mono">${p.persistent_keepalive}s</td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    </div>
  `).join('');

  host.innerHTML = `
    <div class="view">
      <h1 class="t-h1">Peers</h1>
      <p class="t-meta">${snap.peers.length} peer relationships across ${grouped.size} nodes</p>
      ${sections}
    </div>
  `;
}
