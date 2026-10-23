// infra_plugin core: GitHub contents API access to cloud-u-linux, confined to one directory.
// cloud-u-linux is PUBLIC: nothing written here may be secret or mesh-internal.
// Pure (fetch injected), no subprocesses, fetched content is data only: never executed.
export const REPO = "diegonmarcos/cloud-u-linux";
export const PREFIX = "da_my-ai/data/claude/";
export const MAX_WRITE_BYTES = 64 * 1024;
export const MAX_READ_BYTES = 64 * 1024;
const API = "https://api.github.com";

export type Fetch = (url: string, init?: any) => Promise<{ ok: boolean; status: number; json(): Promise<any> }>;

/** Validate and normalise a repo path. Throws BEFORE any network call is possible. */
export function confine(input: unknown): string {
  if (typeof input !== "string" || !input) throw new Error("path required");
  if (input.startsWith("/") || /^[A-Za-z]:/.test(input)) throw new Error("absolute path rejected");
  if (input.includes("..")) throw new Error("'..' rejected");
  if (input.includes("\\") || input.includes("\0") || input.includes("//")) throw new Error("illegal character in path");
  const p = input === PREFIX.slice(0, -1) ? PREFIX : input;
  if (!p.startsWith(PREFIX)) throw new Error(`path must start with ${PREFIX}`);
  for (const seg of p.split("/").filter(Boolean)) {
    if (seg === "." || !/^[A-Za-z0-9._@+-]+$/.test(seg)) throw new Error(`illegal path segment: ${seg}`);
  }
  return p;
}

const SECRET_RES: [string, RegExp][] = [
  ["private key block", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ["AWS access key", /\bAKIA[0-9A-Z]{16}\b/],
  ["GitHub token", /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b/],
  ["Slack token", /\bxox[abprs]-[A-Za-z0-9-]{10,}/],
  ["JWT", /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/],
  ["credential assignment", /(?:password|passwd|secret|api[_-]?key|token)["']?\s*[:=]\s*["']?[A-Za-z0-9+\/_-]{20,}/i],
];
const IP_RE = /\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}|127\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/;

/** Returns the findings (labels only, never the matched text). Empty = clean. */
export function scanContent(text: string): string[] {
  const out = SECRET_RES.filter(([, re]) => re.test(text)).map(([l]) => `secret: ${l}`);
  if (IP_RE.test(text)) out.push("private/mesh IP address");
  return out;
}

/** Body of the contents PUT. sha "new" creates; otherwise it is the blob sha being replaced. */
export function buildPutPayload(message: string, content: string, sha: string) {
  const body: Record<string, string> = {
    message,
    content: Buffer.from(content, "utf8").toString("base64"),
    branch: "main",
  };
  if (sha !== "new") body.sha = sha;
  return body;
}

function headers(token?: string): Record<string, string> {
  const h: Record<string, string> = { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cloud-infra-mcp" };
  if (token) h.Authorization = `Bearer ${token}`;
  return h;
}
async function call(f: Fetch, method: string, url: string, token?: string, body?: unknown) {
  const init: any = { method, headers: headers(token), signal: AbortSignal.timeout(15_000) };
  if (body !== undefined) { init.body = JSON.stringify(body); init.headers["Content-Type"] = "application/json"; }
  const r = await f(url, init);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`GitHub ${r.status}: ${String(j?.message ?? "error").slice(0, 200)}`);
  return j;
}
const contentsUrl = (p: string) => `${API}/repos/${REPO}/contents/${p.replace(/\/$/, "")}?ref=main`;

export async function pluginList(f: Fetch, path: unknown = PREFIX, token?: string) {
  const p = confine(path);
  const j = await call(f, "GET", contentsUrl(p), token);
  if (!Array.isArray(j)) throw new Error("not a directory");
  return j.filter((e: any) => e.type === "file" || e.type === "dir").map((e: any) => ({ type: e.type, path: e.path, size: e.size, sha: e.sha }));
}

export async function pluginRead(f: Fetch, path: unknown, token?: string) {
  const p = confine(path);
  const j = await call(f, "GET", contentsUrl(p), token);
  if (Array.isArray(j) || j.type !== "file") throw new Error(`not a regular file (type=${Array.isArray(j) ? "dir" : j.type}); symlinks are rejected`);
  if (j.size > MAX_READ_BYTES) throw new Error(`file is ${j.size} bytes, read cap ${MAX_READ_BYTES}`);
  return { path: j.path, sha: j.sha, size: j.size, content: Buffer.from(j.content ?? "", "base64").toString("utf8") };
}

export async function pluginWrite(f: Fetch, a: { path: unknown; content: string; sha: string; message: string }, token?: string) {
  const p = confine(a.path);
  if (p.endsWith("/")) throw new Error("path must be a file");
  if (!token) throw new Error("no GitHub token in this container; write unavailable");
  if (typeof a.sha !== "string" || !a.sha) throw new Error("sha required (blob sha being replaced, or 'new')");
  if (Buffer.byteLength(a.content, "utf8") > MAX_WRITE_BYTES) throw new Error(`content exceeds ${MAX_WRITE_BYTES} bytes`);
  if (!a.message || a.message.length > 200) throw new Error("message required, <= 200 chars");
  const bad = scanContent(a.content + "\n" + a.message);
  if (bad.length) throw new Error(`refused, cloud-u-linux is PUBLIC: ${bad.join("; ")}`);
  if (a.sha !== "new") {
    const cur = await call(f, "GET", contentsUrl(p), token);
    if (Array.isArray(cur) || cur.type !== "file") throw new Error("target is not a regular file (symlink/dir rejected)");
    if (cur.sha !== a.sha) throw new Error(`sha mismatch: current is ${cur.sha}`);
  }
  const put = await call(f, "PUT", `${API}/repos/${REPO}/contents/${p}`, token, buildPutPayload(a.message, a.content, a.sha));
  const commit = String(put?.commit?.sha ?? "");
  let run = `https://github.com/${REPO}/commit/${commit}/checks`;
  try {
    const runs = await call(f, "GET", `${API}/repos/${REPO}/actions/runs?head_sha=${commit}&per_page=1`, token);
    if (runs?.workflow_runs?.[0]?.html_url) run = runs.workflow_runs[0].html_url;
  } catch { /* checks URL is the fallback */ }
  return { commit, file_sha: put?.content?.sha, ci: run };
}

export async function pluginDeploy(f: Fetch, token?: string) {
  const wfs = await call(f, "GET", `${API}/repos/${REPO}/actions/workflows`, token);
  const hit = (wfs?.workflows ?? []).find((w: any) => /(^|\/)dotfiles[-_a-z0-9]*\.ya?ml$/i.test(String(w.path)) && w.state === "active");
  if (!hit) return { available: false, message: "not available yet: cloud-u-linux has no workflow that runs the my-ai dotfiles engine" };
  if (!token) throw new Error("no GitHub token in this container; dispatch unavailable");
  await call(f, "POST", `${API}/repos/${REPO}/actions/workflows/${hit.id}/dispatches`, token, { ref: "main" });
  return { available: true, dispatched: hit.path, runs: `https://github.com/${REPO}/actions/workflows/${String(hit.path).split("/").pop()}` };
}
