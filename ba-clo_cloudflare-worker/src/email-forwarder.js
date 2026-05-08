// Cloudflare Email Worker - Triple-delivery inbound email
// Copy 1: ALWAYS → Maddy via smtp-proxy (self-hosted primary)
// Copy 2: ALWAYS → Google Workspace via Gmail API (service account JWT)
// Copy 3: ONLY if C3 health check says mail unhealthy → live.com (disaster backup)

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);

    const rawEmail = await new Response(message.raw).text();

    // Fire all three in parallel: Maddy + Google + health check
    const [maddyOk, googleOk, healthy] = await Promise.all([
      deliverToMaddy(rawEmail, to, env),
      deliverToGoogle(rawEmail, env),
      checkMailHealth(env),
    ]);

    console.log(`Results: maddy=${maddyOk}, google=${googleOk}, healthy=${healthy}`);

    // If health check says unhealthy, send disaster backup to live.com
    if (!healthy) {
      ctx.waitUntil(forwardToBackup(message, env, `mail health: unhealthy, maddy=${maddyOk}`));
    }

    // Accept the email if at least one delivery succeeded
    if (maddyOk || googleOk) {
      return;
    }

    // Both failed — reject with error
    console.error(`All deliveries failed — rejecting`);
    message.setReject(`Primary (Maddy) and secondary (Google) delivery both failed`);
  }
};

// ── Maddy delivery via smtp-proxy ────────────────────────────────
async function deliverToMaddy(rawEmail, to, env) {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10000);
    const response = await fetch(env.SMTP_PROXY_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'text/plain',
        // Bearer auth gates Caddy's forward_auth (api.diegonmarcos.com/smtp-proxy-api
        // is auth=bearer; introspect-proxy validates against Authelia JWKS).
        'Authorization': `Bearer ${env.C3_BEARER_TOKEN}`,
        // X-API-Key kept as defence-in-depth: smtp-proxy Rust binary validates it
        // even after Caddy passes through. Will be retired when the binary is
        // updated to trust upstream auth-only.
        'X-API-Key': env.SMTP_PROXY_KEY,
        'X-Original-To': to,
      },
      body: rawEmail,
      signal: controller.signal,
    });
    clearTimeout(timeoutId);
    if (!response.ok) {
      console.error(`Maddy smtp-proxy error: ${response.status} ${await response.text()}`);
      return false;
    }
    console.log(`Maddy: delivered via smtp-proxy`);
    return true;
  } catch (e) {
    console.error(`Maddy smtp-proxy failed: ${e.message}`);
    return false;
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

// Import a PEM RSA private key for Web Crypto API
async function importPrivateKey(pem) {
  const pemBody = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
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
