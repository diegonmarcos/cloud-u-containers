import { ImapFlow } from "imapflow";
import { getServer, getAccount } from "./config.js";

export async function withImap<T>(
  server: string,
  account: string,
  fn: (client: ImapFlow) => Promise<T>,
): Promise<T> {
  const srv = getServer(server);
  const creds = getAccount(server, account);

  const client = new ImapFlow({
    host: srv.host,
    port: srv.imap,
    secure: true,
    // Internal WG endpoints (e.g. Stalwart) present a self-signed cert that
    // doesn't match the connect hostname; the WG tunnel already encrypts the
    // link, so skip cert-hostname verification for those flagged servers.
    ...(srv.tlsInsecure ? { tls: { rejectUnauthorized: false } } : {}),
    auth: { user: creds.user, pass: creds.password },
    logger: false,
  });

  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.logout();
  }
}
