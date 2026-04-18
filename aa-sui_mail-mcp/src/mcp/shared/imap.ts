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
