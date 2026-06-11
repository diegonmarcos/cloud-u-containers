import type { Snapshot, Node, Peer } from '../modules/types';
import { escapeHtml } from '../modules/format';

// Hand-rolled SVG topology — hub at center, spokes around the perimeter,
// edges colored by transport. ~200 lines, no dep.

interface Pos { x: number; y: number }

function layout(nodes: Node[]): Map<string, Pos> {
  const pos = new Map<string, Pos>();
  const W = 800, H = 460;
  const cx = W / 2, cy = H / 2;
  const hub = nodes.find(n => n.role === 'hub');
  if (hub) pos.set(hub.name, { x: cx, y: cy });
  const others = nodes.filter(n => n.role !== 'hub');
  const r = Math.min(W, H) * 0.36;
  others.forEach((n, i) => {
    const angle = (i / Math.max(1, others.length)) * Math.PI * 2 - Math.PI / 2;
    pos.set(n.name, { x: cx + r * Math.cos(angle), y: cy + r * Math.sin(angle) });
  });
  return pos;
}

function edgeKind(_p: Peer, fromNode: Node | undefined, toNode: Node | undefined): 'udp' | 'tcp' {
  // Default UDP. If either endpoint is a wstunnel-client, edge is TCP.
  if (fromNode?.wstunnel_client || toNode?.wstunnel_client) return 'tcp';
  return 'udp';
}

export function renderTopology(host: HTMLElement, snap: Snapshot): void {
  const W = 800, H = 460;
  const pos = layout(snap.nodes);
  const byName = new Map(snap.nodes.map(n => [n.name, n] as const));

  // De-duplicate undirected edges
  const seen = new Set<string>();
  const edges: { from: Node; to: Node; fromPos: Pos; toPos: Pos; kind: 'udp' | 'tcp' }[] = [];
  for (const p of snap.peers) {
    const a = p.from, b = p.to;
    const key = a < b ? `${a}|${b}` : `${b}|${a}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const fromN = byName.get(a); const toN = byName.get(b);
    const fromP = pos.get(a);    const toP   = pos.get(b);
    if (!fromN || !toN || !fromP || !toP) continue;
    edges.push({ from: fromN, to: toN, fromPos: fromP, toPos: toP, kind: edgeKind(p, fromN, toN) });
  }

  const edgesSvg = edges.map(e => `
    <line class="topo-edge is-${e.kind}" x1="${e.fromPos.x}" y1="${e.fromPos.y}" x2="${e.toPos.x}" y2="${e.toPos.y}">
      <title>${escapeHtml(e.from.name)} ↔ ${escapeHtml(e.to.name)} · ${e.kind.toUpperCase()}</title>
    </line>
  `).join('');

  const nodesSvg = snap.nodes.map(n => {
    const p = pos.get(n.name); if (!p) return '';
    const r = n.role === 'hub' ? 26 : 20;
    return `
      <g class="topo-node" transform="translate(${p.x},${p.y})">
        <title>${escapeHtml(n.name)} (${escapeHtml(n.role)}) · ${escapeHtml(n.public_ip)} → ${escapeHtml(n.wg_ip)}</title>
        <circle class="topo-node__circle is-${n.role}" r="${r}" />
        <text class="topo-node__label" y="${r + 14}">${escapeHtml(n.name)}</text>
        <text class="topo-node__sublabel" y="${r + 28}">${escapeHtml(n.wg_ip)}</text>
      </g>
    `;
  }).join('');

  host.innerHTML = `
    <div class="view">
      <h1 class="t-h1">Topology</h1>
      <p class="t-meta">Hub-and-spoke · ${edges.length} edges · transport-colored</p>

      <div class="topology u-mt-4">
        <header class="topology__head">
          <div class="section__title">${snap.nodes.length} nodes</div>
          <div class="topology__legend">
            <span class="topology__legend-item is-hub"><span class="topology__legend-item__swatch"></span>Hub</span>
            <span class="topology__legend-item is-spoke"><span class="topology__legend-item__swatch"></span>Spoke</span>
            <span class="topology__legend-item is-client"><span class="topology__legend-item__swatch"></span>Client</span>
            <span class="topology__legend-item is-udp"><span class="topology__legend-item__swatch"></span>UDP</span>
            <span class="topology__legend-item is-tcp"><span class="topology__legend-item__swatch"></span>TCP/443</span>
          </div>
        </header>
        <svg class="topology__svg" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="WireGuard mesh topology">
          ${edgesSvg}
          ${nodesSvg}
        </svg>
      </div>
    </div>
  `;
}
