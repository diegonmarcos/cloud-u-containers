import { ImapFlow } from "imapflow";
import { resolveAccount } from "./config.js";

export async function withImap<T>(
  alias: string | undefined,
  fn: (client: ImapFlow, email: string) => Promise<T>,
): Promise<T> {
  const acc = resolveAccount(alias);
  const client = new ImapFlow({
    host: acc.imapHost,
    port: acc.imapPort,
    secure: true,
    auth: { user: acc.email, pass: acc.password },
    logger: false,
  });
  await client.connect();
  try {
    return await fn(client, acc.email);
  } finally {
    await client.logout();
  }
}
