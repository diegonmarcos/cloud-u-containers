// Cloudflare Email Worker - Forward to Mailu (Primary) with backup fallback
// Inbound flow: Internet → Cloudflare MX → Worker → smtp-proxy (oci-mail:8080) → Mailu front:25
// Fallback: if Mailu unhealthy OR smtp-proxy unreachable, forward to BACKUP_EMAIL
//
// Health check: GET /c3-api/health/tools-mailu (C3 API on oci-apps)
// Validates Mailu containers are running + healthy before attempting delivery

export default {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);

    // Step 1: Check Mailu health via C3 API
    let mailuHealthy = false;
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 5000);

      const healthResp = await fetch(env.C3_HEALTH_URL, {
        headers: { 'X-API-Key': env.C3_API_KEY },
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      if (healthResp.ok) {
        const health = await healthResp.json();
        mailuHealthy = health.up && health.healthy;
        if (!mailuHealthy) {
          console.warn(`Mailu unhealthy: up=${health.up}, healthy=${health.healthy}, status=${health.status}`);
        }
      } else {
        console.warn(`C3 health check returned ${healthResp.status}`);
      }
    } catch (e) {
      console.warn(`C3 health check failed: ${e.message}`);
    }

    // Step 2: If healthy, deliver via smtp-proxy
    if (mailuHealthy) {
      const rawEmail = await new Response(message.raw).text();
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
    }

    // Step 3: Fallback — forward to backup email
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
