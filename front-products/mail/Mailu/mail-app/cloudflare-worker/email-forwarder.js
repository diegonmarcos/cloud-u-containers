// Cloudflare Email Worker - Forward to Mailu (Primary) with Google Workspace backup
// Inbound flow: Internet -> Cloudflare (port 25) -> Worker -> Mailu SMTP Proxy -> Mailu
// Backup: If Mailu fails, forward to Google Workspace

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);

    // Get raw email content
    const rawEmail = await new Response(message.raw).text();

    // Primary: Forward to Mailu via SMTP proxy
    try {
      const response = await fetch(env.SMTP_PROXY_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'text/plain',
          'X-API-Key': env.SMTP_PROXY_KEY,
        },
        body: rawEmail,
      });

      if (response.ok) {
        console.log(`Email delivered to Mailu via SMTP proxy`);
        return; // Success - don't need backup
      } else {
        console.error(`SMTP proxy error: ${response.status} ${await response.text()}`);
      }
    } catch (e) {
      console.error(`SMTP proxy failed: ${e.message}`);
    }

    // Backup: Forward to Google Workspace (only if primary fails)
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
