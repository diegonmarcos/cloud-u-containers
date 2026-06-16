// config.ts — data-driven from build.json (FIRE RULE 3: never hardcode data)
// Reads accounts list, IMAP/SMTP host:port, and per-account App Password env vars
// from build.json injected at container build time.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { z } from "zod";

const buildJsonPath = process.env.BUILD_JSON_PATH ?? resolve(process.cwd(), "build.json");

interface AuthSpec {
  mode: "app_password" | "oauth";
  imap_host: string;
  imap_port: number;
  smtp_host: string;
  smtp_port: number;
  tls: boolean;
}

interface AccountSpec {
  alias: string;
  email: string;
  secret_env: string;
  default?: boolean;
}

interface BuildJson {
  name: string;
  auth: AuthSpec;
  accounts: AccountSpec[];
}

let cached: BuildJson | null = null;

function loadBuildJson(): BuildJson {
  if (cached) return cached;
  // Try multiple resolution strategies (container WORKDIR, src/code, src/)
  const candidates = [
    process.env.BUILD_JSON_PATH,
    resolve(process.cwd(), "build.json"),
    resolve(process.cwd(), "../build.json"),
    resolve(process.cwd(), "../../build.json"),
    "/app/build.json",
  ].filter(Boolean) as string[];

  for (const p of candidates) {
    try {
      const raw = readFileSync(p, "utf8");
      cached = JSON.parse(raw) as BuildJson;
      return cached;
    } catch { /* try next */ }
  }
  throw new Error(`build.json not found. Tried: ${candidates.join(", ")}`);
}

export interface AccountCredentials {
  alias: string;
  email: string;
  password: string;
  imapHost: string;
  imapPort: number;
  smtpHost: string;
  smtpPort: number;
}

export function listAccounts(): AccountSpec[] {
  return loadBuildJson().accounts;
}

export function getDefaultAccount(): string {
  const accounts = listAccounts();
  const def = accounts.find((a) => a.default);
  if (def) return def.alias;
  if (accounts.length === 1) return accounts[0].alias;
  throw new Error("No default account configured and multiple accounts present. Specify 'account' arg.");
}

export function getAccount(alias: string): AccountCredentials {
  const cfg = loadBuildJson();
  const acc = cfg.accounts.find((a) => a.alias === alias);
  if (!acc) {
    const known = cfg.accounts.map((a) => a.alias).join(", ");
    throw new Error(`Unknown account alias '${alias}'. Configured: ${known}`);
  }
  const password = process.env[acc.secret_env];
  if (!password) {
    throw new Error(`App Password not set for account '${alias}'. Set env var ${acc.secret_env} (via sops secrets pipeline).`);
  }
  return {
    alias: acc.alias,
    email: acc.email,
    password,
    imapHost: process.env.IMAP_HOST ?? cfg.auth.imap_host,
    imapPort: parseInt(process.env.IMAP_PORT ?? String(cfg.auth.imap_port), 10),
    smtpHost: process.env.SMTP_HOST ?? cfg.auth.smtp_host,
    smtpPort: parseInt(process.env.SMTP_PORT ?? String(cfg.auth.smtp_port), 10),
  };
}

export function resolveAccount(aliasOrUndefined?: string): AccountCredentials {
  return getAccount(aliasOrUndefined ?? getDefaultAccount());
}

export function configuredAccountAliases(): string[] {
  return listAccounts()
    .filter((a) => process.env[a.secret_env])
    .map((a) => a.alias);
}

export const accountSchema = z
  .string()
  .optional()
  .describe("Account alias (from build.json accounts[].alias). Defaults to the account marked default:true.");
