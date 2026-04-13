/**
 * Maddy Mail Server admin interface.
 * Maddy uses CLI-based management (maddy creds, maddy imap-acct),
 * not a REST API. Admin operations run via SSH + docker exec.
 */

import { exec as execCb } from "child_process";
import { promisify } from "util";

const execAsync = promisify(execCb);

async function maddyExec(cmd: string): Promise<string> {
  const { stdout } = await execAsync(
    `ssh -o ConnectTimeout=10 -o BatchMode=yes oci-mail 'docker exec maddy ${cmd}'`,
    { timeout: 15000 },
  );
  return stdout.trim();
}

export async function listAccounts(): Promise<string[]> {
  const out = await maddyExec("maddy creds list");
  return out.split("\n").filter(Boolean);
}

export async function listDomains(): Promise<string[]> {
  // Maddy domains are configured in maddy.conf, not a database
  return ["diegonmarcos.com"];
}
