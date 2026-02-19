// Cloudflare Email Worker - Forward to Mailu (Primary) with backup fallback
// Inbound flow: Internet → Cloudflare MX → Worker → smtp-proxy (oci-mail:8080) → Mailu front:25
// Fallback: if smtp-proxy unreachable, forward to BACKUP_EMAIL

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);

    // Get raw email content
    const rawEmail = await new Response(message.raw).text();

    // Primary: POST raw email to smtp-proxy on oci-mail
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
        console.log(`Email delivered to Mailu via SMTP proxy`);
        return;
      } else {
        console.error(`SMTP proxy error: ${response.status} ${await response.text()}`);
      }
    } catch (e) {
      console.error(`SMTP proxy failed: ${e.message}`);
    }

    // Fallback: forward to backup email
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
