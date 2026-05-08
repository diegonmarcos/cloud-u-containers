import type { AppConfig, SiteCfg } from '../config.js';

type Doer = (typeof import('undici'))['request'];

interface FanoutArgs {
  events: unknown[];
  site: SiteCfg;
  cfg: AppConfig;
  ip: string;
  ua: string;
  doRequest: Doer;
}

interface SlugResult { ok: boolean; status?: number; error?: string }

// Server-side fan-out for /f file ingest. Sends the batch to each backend in
// its native format. Pure pass-through stops at /e /s /l — /f is the only
// route that intentionally translates one input into N backend payloads
// because it's a batch ingest, not a single beacon.
export async function fanout(args: FanoutArgs): Promise<Record<string, SlugResult>> {
  const { events, site, cfg, ip, ua, doRequest } = args;
  const results: Record<string, SlugResult> = {};

  const matomo = cfg.backends.e;
  const umami = cfg.backends.s;
  const oo = cfg.backends.l;

  const baseHeaders = {
    'x-forwarded-for': ip,
    'user-agent': ua,
  };

  const tasks: Array<Promise<void>> = [];

  if (matomo && site.matomo_idsite != null) {
    tasks.push((async () => {
      try {
        const body = events
          .map((ev) => {
            const e = ev as Record<string, unknown>;
            const params = new URLSearchParams();
            params.set('idsite', String(site.matomo_idsite));
            params.set('rec', '1');
            if (e.url) params.set('url', String(e.url));
            if (e.action_name) params.set('action_name', String(e.action_name));
            if (e.e_c) params.set('e_c', String(e.e_c));
            if (e.e_a) params.set('e_a', String(e.e_a));
            if (e.e_n) params.set('e_n', String(e.e_n));
            return params.toString();
          })
          .join('\n');
        const resp = await doRequest(matomo.url, {
          method: 'POST',
          headers: { ...baseHeaders, 'content-type': 'application/x-www-form-urlencoded' },
          body,
          headersTimeout: cfg.limits.request_timeout_ms,
        });
        results.e = { ok: resp.statusCode < 400, status: resp.statusCode };
      } catch (err) {
        results.e = { ok: false, error: (err as Error).message };
      }
    })());
  }

  if (umami && site.umami_website_id) {
    tasks.push((async () => {
      try {
        // Umami /api/send accepts one event per request. Send them serially
        // within this slug's task so we don't blow the per-IP budget upstream.
        let lastStatus = 0;
        for (const ev of events) {
          const payload = {
            type: 'event',
            payload: {
              website: site.umami_website_id,
              ...(ev as Record<string, unknown>),
            },
          };
          const resp = await doRequest(umami.url, {
            method: 'POST',
            headers: { ...baseHeaders, 'content-type': 'application/json' },
            body: JSON.stringify(payload),
            headersTimeout: cfg.limits.request_timeout_ms,
          });
          lastStatus = resp.statusCode;
          if (resp.statusCode >= 400) break;
        }
        results.s = { ok: lastStatus < 400, status: lastStatus };
      } catch (err) {
        results.s = { ok: false, error: (err as Error).message };
      }
    })());
  }

  if (oo) {
    tasks.push((async () => {
      try {
        const headers: Record<string, string> = {
          ...baseHeaders,
          'content-type': 'application/json',
        };
        const auth = cfg.resolvedAuthHeaders.l;
        if (auth) headers.authorization = auth;

        const resp = await doRequest(oo.url, {
          method: 'POST',
          headers,
          body: JSON.stringify(events),
          headersTimeout: cfg.limits.request_timeout_ms,
        });
        results.l = { ok: resp.statusCode < 400, status: resp.statusCode };
      } catch (err) {
        results.l = { ok: false, error: (err as Error).message };
      }
    })());
  }

  await Promise.allSettled(tasks);
  return results;
}
