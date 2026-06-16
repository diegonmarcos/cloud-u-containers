import type { Snapshot } from '../modules/types';
import { escapeHtml } from '../modules/format';

export function renderRoutes(host: HTMLElement, snap: Snapshot): void {
  const rows = snap.routes.map(r => {
    const t = snap.transports.find(x => x.name === r.via_transport);
    const proto = t?.protocol ?? 'udp';
    return `
      <tr>
        <td class="t-strong">${escapeHtml(r.src_node)}</td>
        <td class="t-mono">${escapeHtml(r.dst_subnet)}</td>
        <td><span class="pill is-${proto}">${escapeHtml(r.via_transport)}</span></td>
        <td class="t-muted">${escapeHtml(r.comment ?? '')}</td>
      </tr>
    `;
  }).join('');

  host.innerHTML = `
    <div class="view">
      <h1 class="t-h1">Routes</h1>
      <p class="t-meta">${snap.routes.length} route(s) · derived from peer AllowedIPs + transport bindings</p>

      <div class="table-wrap u-mt-4">
        <table class="tbl">
          <thead><tr><th>src node</th><th>dst subnet</th><th>via transport</th><th>comment</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    </div>
  `;
}
