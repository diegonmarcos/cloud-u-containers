import { z } from "zod";

export interface ServerConfig {
  host: string;
  imap: number;
  smtp: number;
  jmap?: string;
  adminUrl?: string;
  sshAlias: string;
  container: string;
}

export interface AccountCredentials {
  user: string;
  password: string;
}

export const DOMAIN = "diegonmarcos.com";

const SERVERS: Record<string, ServerConfig> = {
  maddy: {
    host: process.env.MADDY_HOST ?? "mail.diegonmarcos.com",
    imap: parseInt(process.env.MADDY_IMAP_PORT ?? "993"),
    smtp: parseInt(process.env.MADDY_SMTP_PORT ?? "465"),
    sshAlias: "oci-mail",
    container: "maddy",
  },
  stalwart: {
    host: process.env.STALWART_HOST ?? "jmap.diegonmarcos.com",
    imap: parseInt(process.env.STALWART_IMAP_PORT ?? "2993"),
    smtp: parseInt(process.env.STALWART_SMTP_PORT ?? "2465"),
    jmap: process.env.STALWART_JMAP_URL ?? "https://jmap.diegonmarcos.com:2443",
    adminUrl: process.env.STALWART_ADMIN_URL,
    sshAlias: "oci-mail",
    container: "stalwart",
  },
};

export function getServer(name: string): ServerConfig {
  const srv = SERVERS[name];
  if (!srv) throw new Error(`Unknown server: ${name}. Available: ${Object.keys(SERVERS).join(", ")}`);
  return srv;
}

export function getAccount(server: string, account: string): AccountCredentials {
  const prefix = server.toUpperCase();
  const suffix = account.toUpperCase();

  const user = process.env[`${prefix}_${suffix}_USER`];
  const password = process.env[`${prefix}_${suffix}_PASSWORD`];
  if (user && password) return { user, password };

  // Backward compat: maddy + me falls back to MAIL_USER/MAIL_PASSWORD
  if (server === "maddy" && account === "me") {
    const fallbackUser = process.env.MAIL_USER;
    const fallbackPass = process.env.MAIL_PASSWORD;
    if (fallbackUser && fallbackPass) return { user: fallbackUser, password: fallbackPass };
  }

  throw new Error(`No credentials for ${server}/${account}. Set ${prefix}_${suffix}_USER and ${prefix}_${suffix}_PASSWORD`);
}

export function listServers(): string[] {
  return Object.keys(SERVERS);
}

export function listConfiguredAccounts(server: string): string[] {
  const prefix = server.toUpperCase();
  const accounts: string[] = [];
  for (const suffix of ["ME", "NOREPLY", "ADMIN"]) {
    if (process.env[`${prefix}_${suffix}_USER`]) accounts.push(suffix.toLowerCase());
  }
  if (server === "maddy" && accounts.length === 0 && process.env.MAIL_USER) {
    accounts.push("me");
  }
  return accounts;
}

export const serverSchema = z.enum(["maddy", "stalwart"]).default("maddy").describe("Mail server");
export const accountSchema = z.enum(["me", "noreply", "admin"]).default("me").describe("Account");
