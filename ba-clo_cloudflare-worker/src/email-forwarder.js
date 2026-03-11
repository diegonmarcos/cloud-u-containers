// Cloudflare Email Worker - Dual-copy inbound email
// Copy 1: ALWAYS fire to Mailu via smtp-proxy (fire-and-forget, zero delay)
// Copy 2: In parallel, check /reach/smtp-proxy — if route is broken, forward to backup
//
// Three tiers: /up (alive) → /health (healthy) → /reach (route works)
// We use /reach because it tests the actual path: Cloudflare → Caddy → smtp-proxy

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);

    const rawEmail = await new Response(message.raw).text();

    // Fire both in parallel: deliver to Mailu + check route reachability
    const [delivered, reachable] = await Promise.all([
      deliverToMailu(rawEmail, env),
      checkReach(env),
    ]);

    if (delivered) {
      console.log(`Email delivered to Mailu via SMTP proxy`);
      if (!reachable) {
        // Delivered but route is flaky — send insurance copy
        ctx.waitUntil(forwardBackup(message, env, 'route unreachable but delivery succeeded'));
      }
      return;
    }

    // Delivery failed — forward to backup
    console.warn(`Mailu delivery failed (reachable=${reachable}) — forwarding to backup`);
    if (env.BACKUP_EMAIL) {
      try {
        await message.forward(env.BACKUP_EMAIL);
        console.log(`Email forwarded to backup: ${env.BACKUP_EMAIL}`);
      } catch (e) {
        console.error(`Backup forward failed: ${e.message}`);
        message.setReject(`Delivery failed: ${e.message}`);
      }
    } else {
      message.setReject(`Primary delivery failed and no backup configured`);
    }
  }
};

async function deliverToMailu(rawEmail, env) {
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
    if (!response.ok) {
      console.error(`SMTP proxy error: ${response.status} ${await response.text()}`);
      return false;
    }
    return true;
  } catch (e) {
    console.error(`SMTP proxy failed: ${e.message}`);
    return false;
  }
}

async function checkReach(env) {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 5000);
    const resp = await fetch(env.C3_REACH_URL, {
      headers: { 'Authorization': `Bearer ${env.C3_BEARER_TOKEN}` },
      signal: controller.signal,
    });
    clearTimeout(timeoutId);
    if (!resp.ok) {
      console.warn(`Reach check returned ${resp.status}`);
      return false;
    }
    const data = await resp.json();
    console.log(`Reach: reachable=${data.reachable}, https=${data.https?.ok}, latency=${data.latencyMs}ms`);
    return data.reachable;
  } catch (e) {
    console.warn(`Reach check failed: ${e.message}`);
    return false;
  }
}

async function forwardBackup(message, env, reason) {
  try {
    await message.forward(env.BACKUP_EMAIL);
    console.log(`Insurance copy sent to ${env.BACKUP_EMAIL} (reason: ${reason})`);
  } catch (e) {
    console.warn(`Insurance copy failed: ${e.message}`);
  }
}
