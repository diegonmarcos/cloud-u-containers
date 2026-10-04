import type { Snapshot } from '../modules/types';
import { escapeHtml, fmtTimestamp } from '../modules/format';

export function renderOverview(host: HTMLElement, snap: Snapshot): void {
  const hubs    = snap.nodes.filter(n => n.role === 'hub').length;
  const spokes  = snap.nodes.filter(n => n.role === 'spoke').length;
  const clients = snap.nodes.filter(n => n.role === 'client').length;
  const udp     = snap.transports.find(t => t.protocol === 'udp');
  const tcp     = snap.transports.find(t => t.protocol === 'tcp');
  const wstunnelClients = snap.nodes.filter(n => n.wstunnel_client).length;

  host.innerHTML = `
    <div class="view">
      <h1 class="t-h1">Mesh overview</h1>
      <p class="t-meta">${snap.nodes.length} nodes · ${snap.peers.length} peer-edges · last sync ${fmtTimestamp(snap.health.last_snapshot_at)}</p>

      <div class="kpi-grid u-mt-4">
        <div class="kpi is-hub">
          <div class="kpi__label">Hubs</div>
          <div class="kpi__value">${hubs}</div>
          <div class="kpi__sub">terminate UDP + TCP/443</div>
        </div>
        <div class="kpi is-spoke">
          <div class="kpi__label">Spokes (VMs)</div>
          <div class="kpi__value">${spokes}</div>
          <div class="kpi__sub">cloud VMs on the mesh</div>
        </div>
        <div class="kpi is-client">
          <div class="kpi__label">Clients</div>
          <div class="kpi__value">${clients}</div>
          <div class="kpi__sub">${wstunnelClients} with wstunnel fallback</div>
        </div>
        <div class="kpi is-udp">
          <div class="kpi__label">UDP transport</div>
          <div class="kpi__value">${udp?.active_peers ?? 0}</div>
          <div class="kpi__sub">${escapeHtml(udp?.endpoint ?? '—')}</div>
        </div>
        <div class="kpi is-tcp">
          <div class="kpi__label">TCP/443 fallback</div>
          <div class="kpi__value">${tcp?.active_peers ?? 0}</div>
          <div class="kpi__sub">${escapeHtml(tcp?.endpoint ?? '—')}</div>
        </div>
        <div class="kpi">
          <div class="kpi__label">Health</div>
          <div class="kpi__value">${escapeHtml(snap.health.status)}</div>
          <div class="kpi__sub">${snap.health.tls_expiries.length} cert(s) tracked</div>
        </div>
      </div>

      <div class="section">
        <div class="section__head">
          <div class="section__title">Snapshot metadata</div>
        </div>
        <div class="table-wrap">
          <table class="tbl">
            <tbody>
              <tr><td class="t-label" style="width:200px">schema</td><td class="t-mono">${escapeHtml(snap._meta.schema)}</td></tr>
              <tr><td class="t-label">generated_by</td><td class="t-mono">${escapeHtml(snap._meta.generated_by)}</td></tr>
              <tr><td class="t-label">generated_at</td><td class="t-mono">${escapeHtml(snap._meta.generated_at)}</td></tr>
              <tr><td class="t-label">last_snapshot_at</td><td class="t-mono">${escapeHtml(snap.health.last_snapshot_at)}</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  `;
}
