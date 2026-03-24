/**
 * Mattermost API client for the rig-agentic bot account.
 * Auth via bot token (MM_BOT_TOKEN env var).
 */

const MM_URL = process.env.MM_URL || "http://mattermost:8065";
const MM_BOT_TOKEN = process.env.MM_BOT_TOKEN || "";
const MM_TEAM_ID = process.env.MM_TEAM_ID || "x89hszqz97g6dxytbtx3p5mmkc";
const MM_ADMIN_USERNAME = process.env.MM_ADMIN_USERNAME || "me@diegonmarcos.com";

const log = (msg: string) => process.stderr.write(`[mm-client] ${msg}\n`);

let botUserId: string | null = null;
let defaultDmId: string | null = null;
let diegoUserId: string | null = null;

export async function mmApi(method: string, path: string, body?: unknown): Promise<unknown> {
  if (!MM_BOT_TOKEN) throw new Error("MM_BOT_TOKEN not configured");

  const res = await fetch(`${MM_URL}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${MM_BOT_TOKEN}`,
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`MM API ${method} ${path} (${res.status}): ${text}`);
  }

  if (res.status === 204) return {};
  return res.json();
}

export async function getBotUserId(): Promise<string> {
  if (botUserId) return botUserId;
  const me = (await mmApi("GET", "/api/v4/users/me")) as { id: string };
  botUserId = me.id;
  return botUserId;
}

async function getDiegoUserId(): Promise<string> {
  if (diegoUserId) return diegoUserId;
  const data = (await mmApi("POST", "/api/v4/users/search", {
    term: MM_ADMIN_USERNAME,
  })) as Array<{ id: string }>;
  if (!data.length) throw new Error(`User not found: ${MM_ADMIN_USERNAME}`);
  diegoUserId = data[0].id;
  return diegoUserId;
}

async function getDefaultDm(): Promise<string> {
  if (defaultDmId) return defaultDmId;
  const uid = await getBotUserId();
  const dId = await getDiegoUserId();
  const dm = (await mmApi("POST", "/api/v4/channels/direct", [uid, dId])) as { id: string };
  defaultDmId = dm.id;
  return defaultDmId;
}

export async function resolveChannel(nameOrId?: string): Promise<string> {
  if (!nameOrId) return getDefaultDm();
  if (/^[a-z0-9]{26}$/.test(nameOrId)) return nameOrId;
  const ch = (await mmApi("GET", `/api/v4/teams/${MM_TEAM_ID}/channels/name/${nameOrId}`)) as { id: string };
  return ch.id;
}

export async function searchUsers(term: string): Promise<Array<{ id: string; username: string; email: string }>> {
  return (await mmApi("POST", "/api/v4/users/search", { term })) as Array<{ id: string; username: string; email: string }>;
}

export function isMmConfigured(): boolean {
  return MM_BOT_TOKEN.length > 0;
}

export { MM_TEAM_ID };
