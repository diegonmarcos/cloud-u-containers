import { exec as execCb } from "child_process";
import { promisify } from "util";
import { getServer } from "./config.js";
import { doFetch } from "./jmap.js";

const execAsync = promisify(execCb);

// All connection detail (hostname 10.0.0.3 over the WG mesh, user, identity
// file) lives in the ssh config that ssh-keys.nix writes to
// /opt/ssh-keys/<container>/, bind-mounted read-only at /root/.ssh by
// compose.nix. Without that mount the alias is not just keyless, it is
// unknown, and ssh fails with "Could not resolve hostname oci-mail" — which
// reads like a DNS/mesh outage instead of a missing config file.
//
// That mount is read-only, so the config's `StrictHostKeyChecking accept-new`
// accepts the host key but cannot append it and warns on every single
// connection; the warning lands on stderr and gets spliced into MCP tool
// output. Pinning UserKnownHostsFile to /dev/null with LogLevel=ERROR drops
// that noise while keeping real failures (auth, timeout). Same options as
// cloud-infra-mcp's shared/libs/ssh.ts.
const SSH_OPTS = [
  "-o BatchMode=yes",
  "-o UserKnownHostsFile=/dev/null",
  "-o LogLevel=ERROR",
  "-o ConnectTimeout=10",
].join(" ");

async function sshDockerExec(sshAlias: string, container: string, cmd: string): Promise<string> {
  const { stdout } = await execAsync(
    `ssh ${SSH_OPTS} ${sshAlias} 'docker exec ${container} ${cmd}'`,
    { timeout: 15000 },
  );
  return stdout.trim();
}

export async function stalwartAdminFetch(path: string, opts: RequestInit = {}): Promise<any> {
  // Stalwart's REST API shares the HTTP listener that serves JMAP, so the
  // admin base URL is the JMAP origin. compose.nix pins STALWART_ADMIN_URL to
  // it; fall back to the JMAP URL so a stdio/dev run without that env var
  // still targets a reachable port instead of defaulting to :443, where
  // oci-mail listens on nothing.
  const srv = getServer("stalwart");
  const adminUrl = srv.adminUrl ?? srv.jmap;
  const user = process.env.STALWART_ADMIN_USER;
  const pass = process.env.STALWART_ADMIN_PASSWORD;
  if (!adminUrl || !user || !pass) throw new Error("STALWART_ADMIN_URL/USER/PASSWORD not set");

  const url = `${adminUrl}${path}`;
  // Bare fetch() throws an opaque "fetch failed" TypeError for every transport
  // error — ECONNREFUSED, TLS, DNS all look identical, which is what made the
  // wrong-port misconfiguration above so hard to see. doFetch surfaces
  // err.cause; keep it so the next transport break names itself.
  const resp = await doFetch(url, {
    ...opts,
    headers: {
      Authorization: `Basic ${Buffer.from(`${user}:${pass}`).toString("base64")}`,
      "Content-Type": "application/json",
      ...(opts.headers as Record<string, string> ?? {}),
    },
  }, "Stalwart admin");
  if (!resp.ok) {
    // A 404 here is not "no accounts", it means the management API is not
    // mounted on this Stalwart build — say so instead of letting the caller
    // render an empty list as an answer.
    const hint = resp.status === 404
      ? " — the Stalwart management API is not served at this path on this build; check the deployed Stalwart version/config"
      : "";
    throw new Error(`Stalwart admin ${resp.status} for ${url}${hint}: ${await resp.text()}`);
  }
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
