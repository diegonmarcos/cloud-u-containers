import type { Snapshot } from '../modules/types';
import { escapeHtml, flagFromRegion } from '../modules/format';

export function renderNodes(host: HTMLElement, snap: Snapshot): void {
  const rows = snap.nodes.map(n => `
    <tr>
      <td class="t-strong">${escapeHtml(n.name)}</td>
      <td><span class="pill is-${escapeHtml(n.role)}">${escapeHtml(n.role)}</span></td>
      <td class="t-mono">${escapeHtml(n.public_ip)}</td>
      <td class="t-mono">${escapeHtml(n.wg_ip)}</td>
      <td>${flagFromRegion(n.region)} ${escapeHtml(n.region)}</td>
      <td class="t-muted">${escapeHtml(n.provider)}</td>
      <td class="t-muted">${escapeHtml(n.os)}</td>
      <td class="t-mono t-muted">${escapeHtml(n.public_key_fp ?? '—')}</td>
      <td class="t-mono">${(n.ports_public ?? []).join(' · ') || '<span class="u-muted">none</span>'}</td>
    </tr>
  `).join('');

  host.innerHTML = `
    <div class="view">
      <h1 class="t-h1">Nodes</h1>
      <p class="t-meta">${snap.nodes.length} nodes registered in cloud-data-topology</p>

      <div class="table-wrap u-mt-4">
        <table class="tbl">
          <thead>
            <tr>
              <th>name</th><th>role</th><th>public IP</th><th>WG IP</th>
              <th>region</th><th>provider</th><th>OS</th><th>pubkey</th><th>public ports</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    </div>
  `;
}
