import type { Snapshot } from './types';

declare const globalThis: { PORTAL_DATA?: Record<string, unknown> };

export function loadSnapshot(): Snapshot {
  const bag = globalThis.PORTAL_DATA;
  if (!bag || !('mesh' in bag)) {
    throw new Error('PORTAL_DATA["mesh"] not found. Ensure data-mesh.json.js is loaded BEFORE script.js.');
  }
  return bag.mesh as Snapshot;
}
