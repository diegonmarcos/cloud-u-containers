// Cloudflare Email Worker - Dual-delivery inbound email
// Leg A (Google): ALWAYS → Google Workspace via Gmail API (service account JWT).
//   This is the durable, guaranteed primary — Gmail import essentially never fails,
//   so acceptance of the message is gated on this leg.
// Leg B (mesh/Maddy): ALWAYS → Maddy via http-to-smtp-proxy-api (self-hosted mirror).
//   This is best-effort AT DELIVERY TIME ONLY. It is retried a few times inline for
//   transient failures (e.g. rate limits, 5xx), and if it still fails after retries
//   it is NOT allowed to bounce the mail — Gmail already has the durable copy, and
//   the mesh copy can be reconciled from Gmail later. But a lost leg-B delivery must
//   never be silent: it is always logged with a stable, greppable MESH_LEG_LOST
//   marker (see notifyMeshLegLost) so it can be alarmed on externally and replayed.
// Copy 3: ONLY if C3 health check says mail unhealthy → live.com (disaster backup)
// NOTE: 2026-05-09 — reverted Phase 5 cf-worker-bridge change: new Caddy route on
// gcp-proxy hadn't shipped (Phase 4 pending), worker was 404'ing → mail down. That
// 9-day outage went unnoticed because leg-B failures were swallowed by
// `maddyOk || googleOk` with no distinct signal — this file now fixes that.

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    const messageId = message.headers.get('Message-ID') || '(no Message-ID)';
    console.log(`Email received: ${from} -> ${to} (${messageId})`);

    const rawEmail = await new Response(message.raw).text();

    // Google (guaranteed primary), the FIRST mesh attempt, and the health check all
    // run inline: acceptance is decided on both legs, so neither one failing alone
    // can bounce a message the other already holds. That redundancy is the whole
    // point of running our own mail VM alongside Gmail — if Gmail is the one that
    // fails, a successful mesh delivery must still accept the mail.
    const [googleOk, maddyFirst, healthy] = await Promise.all([
      deliverToGoogle(rawEmail, env),
      deliverToMaddy(rawEmail, to, env),
      checkMailHealth(env),
    ]);
    const maddyOk = maddyFirst.ok;
    console.log(`Results: maddy=${maddyOk}, google=${googleOk}, healthy=${healthy}`);

    // Leg B only: if the inline attempt failed, keep retrying in the background.
    // The observed failure modes (452 4.4.5 rate limit, transient 5xx from the
    // Caddy→c3-public-api→maddy hop) clear up on a short retry. This runs inside
    // ctx.waitUntil so it never blocks the SMTP accept or the worker's deadline.
    if (!maddyOk) {
      ctx.waitUntil(
        deliverToMaddyWithRetry(rawEmail, to, env, 2, [1000, 2000]).then(({ ok, status }) => {
          if (!ok) {
            // Mesh mirror lost. Gmail may still have it, but this must never be
            // silent — that silence is exactly what hid a 9-day outage.
            return notifyMeshLegLost(env, { messageId, from, to, status });
          }
        })
      );
    }

    // If health check says unhealthy, send disaster backup to live.com
    if (!healthy) {
      ctx.waitUntil(forwardToBackup(message, env, `mail health: unhealthy`));
    }

    // Accept as long as at least one durable copy landed. Never bounce mail that
    // one of the two stores already has.
    if (maddyOk || googleOk) {
      return;
    }

    // Both legs failed — reject so the sending MTA retries rather than us silently
    // dropping the message.
    console.error(`Primary (Google) and mesh (Maddy) delivery both failed — rejecting`);
    message.setReject(`Primary (Google) and mesh (Maddy) delivery both failed`);
  }
};

// ── Leg B retry wrapper ───────────────────────────────────────────────────────
// Bounded retry for the mesh leg: the failures we've actually seen in production
// (452 4.4.5 rate limit, transient 5xx from the Caddy→c3-public-api→maddy hop) are
// exactly the kind that clear up on a short retry. Each attempt still has its own
// AbortController timeout via deliverToMaddy.
async function deliverToMaddyWithRetry(rawEmail, to, env, attempts, backoffsMs) {
  let lastStatus = 'unknown';
  for (let i = 0; i < attempts; i++) {
    const { ok, status } = await deliverToMaddy(rawEmail, to, env);
    if (ok) return { ok: true, status };
    lastStatus = status;
    if (i < attempts - 1) {
      const delay = backoffsMs[i] ?? backoffsMs[backoffsMs.length - 1];
      console.warn(`Maddy delivery attempt ${i + 1}/${attempts} failed (${status}), retrying in ${delay}ms`);
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }
  return { ok: false, status: lastStatus };
}

// ── Loud failure signal for a lost mesh leg ───────────────────────────────────
// No ntfy/Telegram/webhook/KV/D1/Queue binding currently exists in this worker's
// wrangler.toml (only Gmail + Maddy + health-check vars/secrets), so per policy we
// do not invent new Cloudflare infrastructure here. Instead this emits a durable,
// stable-prefixed log line (MESH_LEG_LOST) carrying everything needed to replay
// the message from Gmail; an external log drain/alert on Workers Logs can alarm on
// this prefix. If a notification binding (ntfy/Telegram/webhook) is added to this
// worker later, wire it in here.
async function notifyMeshLegLost(env, { messageId, from, to, status }) {
  console.error(
    `MESH_LEG_LOST message_id=${messageId} from=${from} to=${to} status=${status}`
  );
}

// ── Maddy delivery via http-to-smtp-proxy-api ────────────────────────────────
async function deliverToMaddy(rawEmail, to, env) {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10000);
    const response = await fetch(env.HTTP_TO_SMTP_PROXY_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'text/plain',
        // Bearer auth gates Caddy's forward_auth (api.diegonmarcos.com/http-to-smtp-proxy-api
        // is auth=bearer; introspect-proxy validates against Authelia JWKS).
        'Authorization': `Bearer ${env.C3_BEARER_TOKEN}`,
        // X-API-Key kept as defence-in-depth: http-to-smtp-proxy-api Rust binary validates it
        // even after Caddy passes through. Will be retired when the binary is
        // updated to trust upstream auth-only.
        'X-API-Key': env.HTTP_TO_SMTP_PROXY_API_KEY,
        'X-Original-To': to,
      },
      body: rawEmail,
      signal: controller.signal,
    });
    clearTimeout(timeoutId);
    if (!response.ok) {
      const bodyText = await response.text();
      console.error(`Maddy http-to-smtp-proxy-api error: ${response.status} ${bodyText}`);
      return { ok: false, status: `HTTP ${response.status}: ${bodyText}`.slice(0, 200) };
    }
    console.log(`Maddy: delivered via http-to-smtp-proxy-api`);
    return { ok: true, status: 'ok' };
  } catch (e) {
    console.error(`Maddy http-to-smtp-proxy-api failed: ${e.message}`);
    return { ok: false, status: e.message };
  }
}

// ── Google Workspace delivery via Gmail API + Service Account JWT ────
// Uses multipart upload so we can set labelIds. Without explicit INBOX,
// messages.import drops into All Mail only — invisible from a normal inbox view.
async function deliverToGoogle(rawEmail, env) {
  try {
    const accessToken = await getGoogleAccessToken(env);
    if (!accessToken) {
      console.error('Google: failed to get access token');
      return false;
    }

    const boundary = `boundary_${crypto.randomUUID()}`;
    const metadata = JSON.stringify({ labelIds: ['INBOX', 'UNREAD'] });
    const body =
      `--${boundary}\r\n` +
      `Content-Type: application/json; charset=UTF-8\r\n\r\n` +
      `${metadata}\r\n` +
      `--${boundary}\r\n` +
      `Content-Type: message/rfc822\r\n\r\n` +
      `${rawEmail}\r\n` +
      `--${boundary}--`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 15000);
    const resp = await fetch(
      `https://gmail.googleapis.com/upload/gmail/v1/users/${env.GOOGLE_EMAIL}/messages/import?uploadType=multipart&internalDateSource=dateHeader`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'Content-Type': `multipart/related; boundary="${boundary}"`,
        },
        body: body,
        signal: controller.signal,
      }
    );
    clearTimeout(timeoutId);

    if (!resp.ok) {
      const err = await resp.text();
      console.error(`Google Gmail API error: ${resp.status} ${err}`);
      return false;
    }
    const result = await resp.json();
    console.log(`Google: injected via Gmail API, id=${result.id}, labels=INBOX,UNREAD`);
    return true;
  } catch (e) {
    console.error(`Google Gmail API failed: ${e.message}`);
    return false;
  }
}

// Sign a JWT with RS256 and exchange for a Google access token
async function getGoogleAccessToken(env) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: env.GOOGLE_SA_EMAIL,
    sub: env.GOOGLE_EMAIL,
    scope: 'https://www.googleapis.com/auth/gmail.modify',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };

  const header = { alg: 'RS256', typ: 'JWT' };
  const headerB64 = base64urlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const claimsB64 = base64urlEncode(new TextEncoder().encode(JSON.stringify(claims)));
  const unsignedToken = `${headerB64}.${claimsB64}`;

  // Import the PEM private key
  const key = await importPrivateKey(env.GOOGLE_SA_KEY);
  const signature = await crypto.subtle.sign(
    { name: 'RSASSA-PKCS1-v1_5' },
    key,
    new TextEncoder().encode(unsignedToken)
  );
  const signatureB64 = base64urlEncode(new Uint8Array(signature));
  const jwt = `${unsignedToken}.${signatureB64}`;

  // Exchange JWT for access token
  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });

  if (!resp.ok) {
    const err = await resp.text();
    console.error(`Google token exchange failed: ${resp.status} ${err}`);
    return null;
  }
  const data = await resp.json();
  return data.access_token;
}

// Import a PEM RSA private key for Web Crypto API.
// Accepts: raw PEM, PEM with literal "\n" escapes, or full GCP SA JSON.
async function importPrivateKey(pem) {
  let raw = pem.trim();
  if (raw.startsWith('{')) {
    try { raw = JSON.parse(raw).private_key || raw; } catch {}
  }
  const pemBody = raw
    .replace(/\\n/g, '\n')
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s/g, '');
  const binaryDer = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));
  return crypto.subtle.importKey(
    'pkcs8',
    binaryDer.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  );
}

// base64url encoding (no padding)
function base64urlEncode(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// ── Health check ────────────────────────────────────────────────────
async function checkMailHealth(env) {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 5000);
    const resp = await fetch(env.C3_HEALTH_URL, {
      headers: { 'Authorization': `Bearer ${env.C3_BEARER_TOKEN}` },
      signal: controller.signal,
    });
    clearTimeout(timeoutId);
    if (!resp.ok) {
      console.warn(`Health check returned ${resp.status}`);
      return false;
    }
    const data = await resp.json();
    console.log(`Health: status=${data.status}, reachable=${data.reachable}`);
    return data.status === 'healthy' || data.reachable === true;
  } catch (e) {
    console.warn(`Health check failed: ${e.message}`);
    return false;
  }
}

// ── Disaster backup to live.com ─────────────────────────────────────
async function forwardToBackup(message, env, reason) {
  try {
    await message.forward(env.BACKUP_EMAIL);
    console.log(`Backup: forwarded to ${env.BACKUP_EMAIL} (reason: ${reason})`);
  } catch (e) {
    console.warn(`Backup forward failed: ${e.message}`);
  }
}
