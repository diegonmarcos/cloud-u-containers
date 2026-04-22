import { exec as execCb } from "child_process";
import { promisify } from "util";
import { getServer } from "./config.js";

const execAsync = promisify(execCb);

async function sshDockerExec(sshAlias: string, container: string, cmd: string): Promise<string> {
  const { stdout } = await execAsync(
    `ssh -o ConnectTimeout=10 -o BatchMode=yes ${sshAlias} 'docker exec ${container} ${cmd}'`,
    { timeout: 15000 },
  );
  return stdout.trim();
}

export async function stalwartAdminFetch(path: string, opts: RequestInit = {}): Promise<any> {
  const adminUrl = process.env.STALWART_ADMIN_URL;
  const user = process.env.STALWART_ADMIN_USER;
  const pass = process.env.STALWART_ADMIN_PASSWORD;
  if (!adminUrl || !user || !pass) throw new Error("STALWART_ADMIN_URL/USER/PASSWORD not set");

  const resp = await fetch(`${adminUrl}${path}`, {
    ...opts,
    headers: {
      Authorization: `Basic ${Buffer.from(`${user}:${pass}`).toString("base64")}`,
      "Content-Type": "application/json",
      ...(opts.headers as Record<string, string> ?? {}),
    },
  });
  if (!resp.ok) throw new Error(`Stalwart admin ${resp.status}: ${await resp.text()}`);
  const text = await resp.text();
  return text ? JSON.parse(text) : {};
}

export async function listAccounts(server: string): Promise<string[]> {
  const srv = getServer(server);
  if (server === "maddy") {
    const out = await sshDockerExec(srv.sshAlias, srv.container, "maddy creds list");
    return out.split("\n").filter(Boolean);
  }
  if (server === "stalwart") {
    const data = await stalwartAdminFetch("/api/principal?type=individual&limit=100");
    const items = data?.data?.items ?? data?.items ?? [];
    return items.map((p: any) => typeof p === "string" ? p : p.name ?? p);
  }
  throw new Error(`listAccounts not supported for ${server}`);
}

export async function listDomains(server: string): Promise<string[]> {
  if (server === "maddy") return ["diegonmarcos.com"];
  if (server === "stalwart") {
    const data = await stalwartAdminFetch("/api/principal?type=domain&limit=100");
    const items = data?.data?.items ?? data?.items ?? [];
    return items.map((d: any) => typeof d === "string" ? d : d.name ?? d);
  }
  throw new Error(`listDomains not supported for ${server}`);
}
