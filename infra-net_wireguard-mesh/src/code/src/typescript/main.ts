// wireguard-mesh — entry point
const TAG = '[wg-mesh]';
console.info(TAG, 'script.js evaluated', { ts: Date.now(), readyState: document.readyState });

import { store } from './modules/state';
import { loadSnapshot } from './modules/loader';
import { renderShell, renderTopbar, renderSidebar } from './modules/shell';
import { onRouteChange } from './modules/router';
import { renderOverview }   from './views/overview';
import { renderTopology }   from './views/topology';
import { renderNodes }      from './views/nodes';
import { renderPeers }      from './views/peers';
import { renderTransports } from './views/transports';
import { renderRoutes }     from './views/routes';
import { renderHealth }     from './views/health';
import type { Snapshot } from './modules/types';

const VIEWS: Record<string, (h: HTMLElement, s: Snapshot) => void> = {
  'overview':   renderOverview,
  'topology':   renderTopology,
  'nodes':      renderNodes,
  'peers':      renderPeers,
  'transports': renderTransports,
  'routes':     renderRoutes,
  'health':     renderHealth,
};

function bootstrap(): void {
  console.info(TAG, 'bootstrap');
  const root = document.getElementById('app');
  if (!root) { console.error(TAG, 'no #app'); return; }
  renderShell(root);

  let snap: Snapshot;
  try {
    snap = loadSnapshot();
    console.info(TAG, 'snapshot loaded', {
      nodes: snap.nodes.length,
      peers: snap.peers.length,
      transports: snap.transports.length,
      schema: snap._meta.schema,
    });
  } catch (e) {
    const main = document.getElementById('main');
    if (main) main.innerHTML = `<div class="view"><h1 class="t-h1">Snapshot missing</h1><p class="t-meta">${(e as Error).message}</p></div>`;
    return;
  }

  store.set({ snapshot: snap });
  store.subscribe(() => render(snap));
  onRouteChange(route => { store.set({ route }); });
  render(snap);
}

function render(snap: Snapshot): void {
  const { route } = store.get();
  renderTopbar(snap);
  renderSidebar(route.path);
  const main = document.getElementById('main'); if (!main) return;
  // overview is the guaranteed default — use non-null assertion since the dict literal includes it.
  const fn: (h: HTMLElement, s: Snapshot) => void = VIEWS[route.path] ?? VIEWS.overview!;
  try { fn(main, snap); }
  catch (e) {
    main.innerHTML = `<div class="view"><h1 class="t-h1">Render error</h1><p class="t-meta">${(e as Error).message}</p></div>`;
  }
}

bootstrap();
