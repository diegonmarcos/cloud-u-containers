import { ImapFlow } from "imapflow";

export async function withImap<T>(fn: (client: ImapFlow) => Promise<T>): Promise<T> {
  const client = new ImapFlow({
    host: process.env.MAIL_HOST ?? "mail.diegonmarcos.com",
    port: 993,
    secure: true,
    auth: {
      user: process.env.MAIL_USER!,
      pass: process.env.MAIL_PASSWORD!,
    },
    logger: false,
  });

  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.logout();
  }
}
