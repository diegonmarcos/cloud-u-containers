// ── Ops: push events and DAG triggers ──

import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import { audit } from "./audit.js";
import { syncRepos } from "./paths.js";

// Resolve Dagu API from cloud-data topology (env override available)
function resolveDaguApi(): string {
  if (process.env.DAGU_API) return process.env.DAGU_API;
  try {
    const { readFileSync } = require("fs");
    const { getConfigPath } = require("./paths.js");
    const topo = JSON.parse(readFileSync(getConfigPath(), "utf-8"));
    const svc = topo.services?.dagu;
    const vm = svc?.vm ? topo.vms?.[svc.vm] : null;
    if (vm?.wg_ip && svc?.port) return `http://${vm.wg_ip}:${svc.port}`;
  } catch {}
  return "http://10.0.0.3:8070";
}
const DAGU_API = resolveDaguApi();
const DAGU_USER = process.env.DAGU_USERNAME ?? "";
const DAGU_PASS = process.env.DAGU_PASSWORD ?? "";

// Store last push event for Dagu jobs to read
const EVENTS_DIR = "/tmp/c3-events";
try { mkdirSync(EVENTS_DIR, { recursive: true }); } catch {}

export interface PushEvent {
  ref?: string;
  repo?: string;
  sender?: string;
  head_commit?: { id: string; message: string; timestamp: string };
  commits?: Array<{ id: string; message: string; added: string[]; modified: string[]; removed: string[] }>;
  modified_files?: string[];
}

export interface PushEventResult {
  ok: boolean;
  message: string;
  dagu_triggered: boolean;
  dagu_error?: string;
  event_id: string;
}

export async function handlePushEvent(event: PushEvent): Promise<PushEventResult> {
  const eventId = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 6);

  // Persist event for Dagu/other consumers
  const eventPath = join(EVENTS_DIR, "last-push.json");
  const latestPath = join(EVENTS_DIR, `push-${eventId}.json`);
  const payload = { ...event, event_id: eventId, received_at: new Date().toISOString() };
  writeFileSync(eventPath, JSON.stringify(payload, null, 2));
  writeFileSync(latestPath, JSON.stringify(payload, null, 2));

  // Aggregate modified files from commits if not provided directly
  const modified = event.modified_files ?? extractModifiedFiles(event);

  audit("ops/push-event", event.repo ?? "cloud", `${modified.length} files, event=${eventId}`, "gha");

  // Force-sync local repos so topology/configs reflect the new push
  syncRepos(true);

  // Trigger Dagu cloud-data-sync DAG
  let daguTriggered = false;
  let daguError: string | undefined;

  try {
    const resp = await triggerDag("cloud-data-sync");
    daguTriggered = resp.ok;
    if (!resp.ok) daguError = resp.error;
  } catch (e: unknown) {
    daguError = e instanceof Error ? e.message : String(e);
  }

  const msg = daguTriggered
    ? `Push event received (${modified.length} files). Dagu cloud-data-sync triggered.`
    : `Push event received (${modified.length} files). Dagu trigger failed: ${daguError}`;

  return { ok: true, message: msg, dagu_triggered: daguTriggered, dagu_error: daguError, event_id: eventId };
}

function extractModifiedFiles(event: PushEvent): string[] {
  if (!event.commits?.length) return [];
  const files = new Set<string>();
  for (const c of event.commits) {
    for (const f of c.added ?? []) files.add(f);
    for (const f of c.modified ?? []) files.add(f);
    for (const f of c.removed ?? []) files.add(f);
  }
  return [...files];
}

/** Auth headers for Dagu API (basic auth from env) */
export function daguHeaders(): Record<string, string> {
  const h: Record<string, string> = {};
  if (DAGU_USER && DAGU_PASS) {
    h["Authorization"] = "Basic " + Buffer.from(`${DAGU_USER}:${DAGU_PASS}`).toString("base64");
  }
  return h;
}

/** Dagu API base URL */
export { DAGU_API };

async function triggerDag(name: string): Promise<{ ok: boolean; dagRunId?: string; error?: string }> {
  const url = `${DAGU_API}/api/v2/dags/${name}/start`;

  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...daguHeaders() },
    body: JSON.stringify({}),
    signal: AbortSignal.timeout(15000),
  });

  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    return { ok: false, error: `Dagu API ${resp.status}: ${body}` };
  }

  const data = await resp.json().catch(() => ({})) as { dagRunId?: string };
  return { ok: true, dagRunId: data.dagRunId };
}
