import type { Route2 } from './types';

export function parseHash(hash: string): Route2 {
  const raw = hash.replace(/^#\/?/, '');
  const [path, qs] = raw.split('?');
  const params: Record<string, string> = {};
  if (qs) {
    qs.split('&').forEach(kv => {
      const [k, v] = kv.split('=');
      if (k) params[decodeURIComponent(k)] = decodeURIComponent(v ?? '');
    });
  }
  return { path: path || '', params };
}

export function navigate(path: string, params: Record<string, string> = {}): void {
  const qs = Object.entries(params).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
  location.hash = `#/${path}${qs ? '?' + qs : ''}`;
}

export function onRouteChange(cb: (r: Route2) => void): void {
  const apply = () => {
    let r = parseHash(location.hash);
    if (!r.path) r = { path: 'overview', params: {} };
    cb(r);
  };
  window.addEventListener('hashchange', apply);
  apply();
}
