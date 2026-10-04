// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                  ║
// ║   GENERATED FILE — DO NOT EDIT                                   ║
// ║                                                                  ║
// ║   Source : a_solutions/ba-clo_cloudflare-worker/src/.wrangler/tmp/deploy-Nbvbet/email-forwarder.js
// ║   Engine : 1_workflows/src/scripts/cloud-ship-container-engine.sh
// ║   Rebuild: ./1_workflows/build.sh
// ║                                                                  ║
// ║   Manual edits will be overwritten on next build.                ║
// ║                                                                  ║
// ╚══════════════════════════════════════════════════════════════════╝

var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// email-forwarder.js
var email_forwarder_default = {
  async email(message, env, ctx) {
    const from = message.from;
    const to = message.to;
    console.log(`Email received: ${from} -> ${to}`);
    const rawEmail = await new Response(message.raw).text();
    const [delivered, reachable] = await Promise.all([
      deliverToMailu(rawEmail, env),
      checkReach(env)
    ]);
    if (delivered) {
      console.log(`Email delivered to Mailu via SMTP proxy`);
      if (!reachable) {
        ctx.waitUntil(forwardBackup(message, env, "route unreachable but delivery succeeded"));
      }
      return;
    }
    console.warn(`Mailu delivery failed (reachable=${reachable}) \u2014 forwarding to backup`);
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
    const timeoutId = setTimeout(() => controller.abort(), 5e3);
    const response = await fetch(env.SMTP_PROXY_URL, {
      method: "POST",
      headers: {
        "Content-Type": "text/plain",
        "X-API-Key": env.SMTP_PROXY_KEY
      },
      body: rawEmail,
      signal: controller.signal
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
__name(deliverToMailu, "deliverToMailu");
async function checkReach(env) {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 5e3);
    const resp = await fetch(env.C3_REACH_URL, {
      headers: { "Authorization": `Bearer ${env.C3_BEARER_TOKEN}` },
      signal: controller.signal
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
__name(checkReach, "checkReach");
async function forwardBackup(message, env, reason) {
  try {
    await message.forward(env.BACKUP_EMAIL);
    console.log(`Insurance copy sent to ${env.BACKUP_EMAIL} (reason: ${reason})`);
  } catch (e) {
    console.warn(`Insurance copy failed: ${e.message}`);
  }
}
__name(forwardBackup, "forwardBackup");
export {
  email_forwarder_default as default
};
//# sourceMappingURL=email-forwarder.js.map
