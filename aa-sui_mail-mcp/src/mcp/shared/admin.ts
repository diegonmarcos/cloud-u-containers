/**
 * Stalwart Mail Server admin API client.
 * Replaces Mailu's `docker exec flask mailu` with REST API calls.
 */

const STALWART_API = process.env.STALWART_ADMIN_URL || "https://mail.diegonmarcos.com";
const STALWART_USER = process.env.STALWART_ADMIN_USER || "admin";
const STALWART_PASS = process.env.STALWART_ADMIN_PASSWORD || "";

async function stalwartApi(path: string, method = "GET", body?: unknown): Promise<unknown> {
  const headers: Record<string, string> = {
    "Authorization": `Basic ${Buffer.from(`${STALWART_USER}:${STALWART_PASS}`).toString("base64")}`,
    "Content-Type": "application/json",
  };
  const resp = await fetch(`${STALWART_API}/api${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Stalwart API ${method} ${path}: ${resp.status} ${text}`);
  }
  const text = await resp.text();
  return text ? JSON.parse(text) : null;
}

export async function listAccounts(): Promise<string[]> {
  const data = await stalwartApi("/account") as { items?: string[] };
  return data?.items || [];
}

export async function createAccount(email: string, password: string, name?: string): Promise<void> {
  await stalwartApi("/account", "POST", {
    name: email,
    secret: password,
    description: name || email,
    type: "individual",
    emails: [email],
  });
}

export async function deleteAccount(email: string): Promise<void> {
  await stalwartApi(`/account/${encodeURIComponent(email)}`, "DELETE");
}

export async function listDomains(): Promise<string[]> {
  const data = await stalwartApi("/domain") as { items?: string[] };
  return data?.items || [];
}
