// Cloudflare Email Worker - Dual-copy inbound email
// Copy 1: ALWAYS fire to Mailu via smtp-proxy (fire-and-forget, zero delay)
// Copy 2: Check smtp-proxy reachability — if broken, forward to BACKUP_EMAIL
//
// Health = actual delivery path: Caddy → smtp-proxy → Mailu
// No separate health API needed — the smtp-proxy response IS the health check.

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);

    const rawEmail = await new Response(message.raw).text();

    // Copy 1: deliver to Mailu — this IS the health check too
    const delivered = await deliverToMailu(rawEmail, env);

    if (delivered) {
      console.log(`Email delivered to Mailu via SMTP proxy`);
      return;
    }

    // Copy 1 failed (smtp-proxy/Caddy/Mailu down) — send Copy 2 to backup
    console.warn(`Mailu delivery failed — forwarding to backup`);
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
