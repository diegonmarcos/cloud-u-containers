// Bootstrap for c3-public-api.
// HOST/PORT come from build-c3-public-api.json -> compose.nix env vars; we
// only read them through shared/config.ts which loadConfig() owns.
import { buildApp } from "./app.js";

async function main() {
  const { app, cfg } = await buildApp();

  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      app.log.info({ sig }, "shutting down");
      app.close().then(() => process.exit(0));
    });
  }

  try {
    await app.listen({ host: cfg.host, port: cfg.port });
    app.log.info(
      {
        host: cfg.host,
        port: cfg.port,
        basePath: cfg.basePath,
        backends: Object.keys(cfg.backends),
        mail_primary: `${cfg.mail.primary.host}:${cfg.mail.primary.port}`,
        mail_shadow: cfg.mail.shadow ? `${cfg.mail.shadow.host}:${cfg.mail.shadow.port}` : "disabled",
      },
      "c3-public-api ready",
    );
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
