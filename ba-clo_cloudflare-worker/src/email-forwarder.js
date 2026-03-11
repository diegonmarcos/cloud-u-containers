// Cloudflare Email Worker - Dual-copy inbound email
// Copy 1: ALWAYS fire to Mailu via smtp-proxy (fire-and-forget, zero delay)
// Copy 2: Check health — if Mailu unhealthy, forward to BACKUP_EMAIL
//
// Health check: GET /c3-api/health/mailu-front-1 (single container via topology)

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);

    // Copy 1: fire to Mailu — don't wait, don't care
    const rawEmail = await new Response(message.raw).text();
    ctx.waitUntil(fireToMailu(rawEmail, env));

    // Copy 2: check health — if down, forward to backup
    const healthy = await checkMailuHealth(env);
    if (!healthy && env.BACKUP_EMAIL) {
      try {
        await message.forward(env.BACKUP_EMAIL);
        console.log(`Mailu unhealthy — copy sent to backup: ${env.BACKUP_EMAIL}`);
      } catch (e) {
        console.error(`Backup forward failed: ${e.message}`);
        message.setReject(`Backup delivery failed: ${e.message}`);
      }
    }
  }
};

async function fireToMailu(rawEmail, env) {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 5000);
    const response = await fetch(env.SMTP_PROXY_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'text/plain',
        'X-API-Key': env.SMTP_PROXY_KEY,
      },
      body: rawEmail,
      signal: controller.signal,
    });
    clearTimeout(timeoutId);
    if (response.ok) {
      console.log(`Copy 1: delivered to Mailu via SMTP proxy`);
    } else {
      console.error(`Copy 1: SMTP proxy error ${response.status}`);
    }
  } catch (e) {
    console.error(`Copy 1: SMTP proxy failed: ${e.message}`);
  }
}

async function checkMailuHealth(env) {
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
    const health = await resp.json();
    const ok = health.up && health.healthy;
    if (!ok) console.warn(`Mailu unhealthy: up=${health.up}, healthy=${health.healthy}`);
    return ok;
  } catch (e) {
    console.warn(`Health check failed: ${e.message}`);
    return false;
  }
}
