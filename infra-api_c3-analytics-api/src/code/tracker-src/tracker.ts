// Browser tracker — bundled by tracker-src/build.ts into tracker-dist/tracker.js
// and served at /t.js. Reads window.__c3a_config__ injected by routes/tracker.ts
// for runtime base path + sites mapping (no rebuild needed for new sites).

interface SiteRuntime {
  id: string;
  matomo_idsite: number | string | null;
  umami_website_id: string | null;
  openobserve_stream: string | null;
}

interface RuntimeConfig {
  basePath: string;
  sites: SiteRuntime[];
}

interface TrackPayload {
  url?: string;
  referrer?: string;
  title?: string;
  event?: string;
  [k: string]: unknown;
}

declare global {
  interface Window {
    __c3a_config__?: RuntimeConfig;
    c3a?: {
      track: (sid: string, type: string, payload?: TrackPayload) => void;
    };
  }
}

(function initC3A() {
  const cfg = window.__c3a_config__;
  if (!cfg) return;

  function siteOf(sid: string): SiteRuntime | undefined {
    return cfg!.sites.find((s) => s.id === sid);
  }

  function fireMatomo(site: SiteRuntime, type: string, p: TrackPayload) {
    if (site.matomo_idsite == null) return;
    const params = new URLSearchParams({
      idsite: String(site.matomo_idsite),
      rec: '1',
      url: p.url ?? location.href,
      urlref: p.referrer ?? document.referrer,
      action_name: p.title ?? document.title,
      rand: String(Math.random()),
    });
    if (type === 'event' && p.event) {
      params.set('e_c', 'event');
      params.set('e_a', String(p.event));
    }
    new Image().src = `${cfg!.basePath}/e?${params.toString()}`;
  }

  function fireUmami(site: SiteRuntime, type: string, p: TrackPayload) {
    if (!site.umami_website_id) return;
    const body = JSON.stringify({
      type: type === 'event' ? 'event' : 'event',
      payload: {
        website: site.umami_website_id,
        url: p.url ?? location.pathname + location.search,
        referrer: p.referrer ?? document.referrer,
        title: p.title ?? document.title,
        name: p.event ?? type,
        language: navigator.language,
        screen: `${screen.width}x${screen.height}`,
        hostname: location.hostname,
      },
    });
    fetch(`${cfg!.basePath}/s`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
      keepalive: true,
      credentials: 'omit',
    }).catch(() => {});
  }

  function fireOpenObserve(site: SiteRuntime, type: string, p: TrackPayload) {
    if (!site.openobserve_stream) return;
    const body = JSON.stringify([{
      stream: site.openobserve_stream,
      ts: new Date().toISOString(),
      sid: site.id,
      type,
      url: p.url ?? location.href,
      referrer: p.referrer ?? document.referrer,
      ua: navigator.userAgent,
      ...p,
    }]);
    fetch(`${cfg!.basePath}/l`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
      keepalive: true,
      credentials: 'omit',
    }).catch(() => {});
  }

  window.c3a = {
    track(sid, type, payload = {}) {
      const site = siteOf(sid);
      if (!site) return;
      try { fireMatomo(site, type, payload); } catch {}
      try { fireUmami(site, type, payload); } catch {}
      try { fireOpenObserve(site, type, payload); } catch {}
    },
  };
})();
