/**
 * Pure helpers behind devops.caddy.cert_repair. No imports, no ssh, no fs — so
 * test-caddy-cert-repair.mjs exercises the REAL script builder and parsers.
 *
 * Incident 2026-10-15: overlapping deploys left caddy on gcp-proxy in a restart
 * loop — "caching certificate: tls: private key does not match public key" for
 * mesh-CA certs (c3-services-mcp.app, filebrowser.app, photoprism.app). While
 * caddy crash-loops `docker exec` is useless, so the repair works on the HOST
 * side of the /data mount: move the cert dirs whose .key does not match the
 * .crt out of <data>/caddy/certificates/ (caddy then re-issues), restart caddy.
 * Nothing is deleted; moved dirs keep their files under <data>/caddy/bad-cert-*.
 */

export const CONTAINER_RE = /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/;
/** Host path of the /data mount source: absolute, no spaces/quotes/`..`. */
const HOST_PATH_RE = /^\/[A-Za-z0-9_.\/-]+$/;
export const MISMATCH_RE = /private key does not match/i;

/** `docker inspect` template printing the host source of the container's /data mount. */
export const DATA_MOUNT_TEMPLATE = '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}';

/** Validate the mount source printed by docker inspect; null when unusable. */
export function parseDataMount(stdout: string): string | null {
  const p = stdout.trim();
  if (!HOST_PATH_RE.test(p) || p.split("/").includes("..") || p === "/") return null;
  return p.replace(/\/+$/, "");
}

/** Timestamp for bad-cert-<name>-<ts> dir names: UTC, filesystem-safe. */
export function tsStamp(d: Date = new Date()): string {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
}

export type ScanLine =
  | { kind: "bad"; cert: string }
  | { kind: "okn"; n: number }
  | { kind: "timeout"; left: number }
  | { kind: "skip"; cert: string; why: string }
  | { kind: "moved"; cert: string; to: string }
  | { kind: "mesh"; entries: number }
  | { kind: "mesh_moved"; to: string }
  | { kind: "err"; msg: string }
  | { kind: "done" };

/**
 * Bash run on the HOST (as root) in ONE ssh invocation. `allMesh` quarantines the whole
 * certificates/mesh dir instead of probing each cert. `dryRun` reports only; it never
 * touches a file. Only mismatches are emitted (OK certs are just counted: `OKN <n>`);
 * the pubkey of cert and key are compared in-shell, so no key material reaches stdout.
 * `budgetSec` caps the scan (`TIMEOUT <n>` = certs not checked). With `container` (and
 * no `dataDir`) the /data mount is resolved on the host; a dry run then appends state +
 * recent logs, a live run issues an ASYNC restart and returns immediately.
 */
export function buildRepairScript(o: { dataDir?: string; container?: string; allMesh: boolean; dryRun: boolean; ts: string; budgetSec?: number }): string {
  if (o.dataDir !== undefined && (!HOST_PATH_RE.test(o.dataDir) || o.dataDir.split("/").includes(".."))) throw new Error(`Invalid data dir: ${o.dataDir}`);
  if (o.dataDir === undefined && !o.container) throw new Error("Invalid data dir: need dataDir or container");
  if (o.container !== undefined && !CONTAINER_RE.test(o.container)) throw new Error(`Invalid container: ${o.container}`);
  if (!/^[0-9]{8}T[0-9]{6}Z$/.test(o.ts)) throw new Error(`Invalid timestamp: ${o.ts}`);
  const budget = Math.max(1, Math.min(Math.floor(o.budgetSec ?? 25), 40));
  const c = o.container;
  return [
    "set -u",
    `D='${o.dataDir ?? ""}'; TS='${o.ts}'; ALL=${o.allMesh ? 1 : 0}; DRY=${o.dryRun ? 1 : 0}; BUDGET=${budget}; SECONDS=0`,
    ...(c ? [`[ -n "$D" ] || D=$(docker inspect -f '${DATA_MOUNT_TEMPLATE}' ${c} 2>/dev/null)`] : []),
    'D="${D%/}"',
    'if [[ ! "$D" =~ ^/[A-Za-z0-9_./-]+$ ]] || [[ "$D" == *..* ]]; then echo "ERR no usable /data mount (got: ${D:0:80})"; exit 5; fi',
    'echo "DATA $D"',
    'ROOT="$D/caddy/certificates"',
    'command -v openssl >/dev/null 2>&1 || { echo "ERR openssl not installed on the host"; exit 3; }',
    '[ -d "$ROOT" ] || { echo "ERR no certificates dir at $ROOT"; exit 4; }',
    'if [ "$ALL" = 1 ]; then',
    '  if [ -d "$ROOT/mesh" ]; then',
    '    echo "MESH $(find "$ROOT/mesh" -mindepth 1 -maxdepth 1 | wc -l)"',
    '    if [ "$DRY" = 0 ]; then',
    '      if mv -- "$ROOT/mesh" "$D/caddy/bad-cert-mesh-$TS"; then echo "MESH_MOVED $D/caddy/bad-cert-mesh-$TS"; else echo "ERR could not move $ROOT/mesh"; fi',
    "    fi",
    "  else echo \"MESH 0\"; fi",
    "fi",
    "okn=0; left=0",
    'for idir in "$ROOT"/*/; do',
    '  [ -d "$idir" ] || continue',
    '  iss="${idir%/}"; iss="${iss##*/}"',
    '  if [ "$ALL" = 1 ] && [ "$iss" = mesh ]; then continue; fi',
    '  for d in "$idir"*/; do',
    '    [ -d "$d" ] || continue',
    '    if [ "$SECONDS" -ge "$BUDGET" ]; then left=$((left+1)); continue; fi',
    '    name="${d%/}"; name="${name##*/}"',
    '    crt=""; for c in "$d"*.crt; do [ -f "$c" ] && { crt="$c"; break; }; done',
    '    if [ -z "$crt" ]; then echo "SKIP $iss/$name no .crt"; continue; fi',
    '    key="${crt%.crt}.key"',
    '    if [ ! -f "$key" ]; then echo "SKIP $iss/$name no .key"; continue; fi',
    '    pa=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)',
    '    pb=$(openssl pkey -in "$key" -pubout 2>/dev/null)',
    '    if [ -z "$pa" ] || [ -z "$pb" ]; then echo "SKIP $iss/$name unreadable cert or key"; continue; fi',
    '    if [ "$pa" = "$pb" ]; then okn=$((okn+1)); continue; fi',
    '    echo "BAD $iss/$name"',
    '    if [ "$DRY" = 0 ]; then',
    '      dst="$D/caddy/bad-cert-$name-$TS"; [ -e "$dst" ] && dst="$dst-$iss"',
    '      if mv -- "${d%/}" "$dst"; then echo "MOVED $iss/$name $dst"; else echo "ERR could not move $iss/$name"; fi',
    "    fi",
    "  done",
    "done",
    'echo "OKN $okn"',
    '[ "$left" = 0 ] || echo "TIMEOUT $left"',
    'echo "DONE"',
    ...(c
      ? [
          'if [ "$DRY" = 1 ]; then',
          `  echo "STATE $(docker inspect -f '${STATE_TEMPLATE}' ${c} 2>&1)"`,
          '  echo "===LOGS==="',
          `  timeout 8 docker logs --tail 400 ${c} 2>&1`,
          "else",
          `  nohup docker restart -t 5 ${c} >/dev/null 2>&1 </dev/null &`,
          '  echo "RESTARTING"',
          "fi",
        ]
      : []),
  ].join("\n");
}

export function parseScanOutput(out: string): ScanLine[] {
  const res: ScanLine[] = [];
  for (const raw of out.split("\n")) {
    const l = raw.trim();
    let m: RegExpExecArray | null;
    if ((m = /^BAD (\S+)$/.exec(l))) res.push({ kind: "bad", cert: m[1] });
    else if ((m = /^OKN (\d+)$/.exec(l))) res.push({ kind: "okn", n: Number(m[1]) });
    else if ((m = /^TIMEOUT (\d+)$/.exec(l))) res.push({ kind: "timeout", left: Number(m[1]) });
    else if ((m = /^SKIP (\S+) (.+)$/.exec(l))) res.push({ kind: "skip", cert: m[1], why: m[2] });
    else if ((m = /^MOVED (\S+) (\S+)$/.exec(l))) res.push({ kind: "moved", cert: m[1], to: m[2] });
    else if ((m = /^MESH (\d+)$/.exec(l))) res.push({ kind: "mesh", entries: Number(m[1]) });
    else if ((m = /^MESH_MOVED (\S+)$/.exec(l))) res.push({ kind: "mesh_moved", to: m[1] });
    else if ((m = /^ERR (.+)$/.exec(l))) res.push({ kind: "err", msg: m[1] });
    else if (l === "DONE") res.push({ kind: "done" });
  }
  return res;
}

/** "issuer/name" -> name (the domain). */
export const certDomain = (cert: string): string => cert.slice(cert.indexOf("/") + 1);

/** Lines of `docker logs` that report a key/cert mismatch (trimmed, capped). */
export function mismatchLines(logs: string, max = 10): string[] {
  return logs.split("\n").map((l) => l.trim()).filter((l) => MISMATCH_RE.test(l)).slice(0, max).map((l) => l.slice(0, 400));
}

/** Domains named in mismatch lines: JSON `"identifier"`/`"subject"` fields, else any hostname-looking token. */
export function mismatchDomains(logs: string): string[] {
  const found = new Set<string>();
  for (const l of mismatchLines(logs, 200)) {
    for (const m of l.matchAll(/(?:identifier|subject|domain|name|certificate)["']?\s*[:=]\s*["']?([A-Za-z0-9*_.-]+\.[A-Za-z]{2,})/g)) found.add(m[1].toLowerCase());
    for (const m of l.matchAll(/\b((?:[a-z0-9_-]+\.)+[a-z]{2,})\b/gi)) {
      const h = m[1].toLowerCase();
      if (!/^(tls|caddy|http|cache|golang)\./.test(h) && !h.endsWith(".go")) found.add(h);
    }
  }
  return [...found];
}

function summarize(line: string): string {
  const t = line.trim();
  if (t.startsWith("{")) {
    try {
      const j = JSON.parse(t) as Record<string, unknown>;
      const parts = [j.level, j.logger, j.msg, j.error].filter((v) => typeof v === "string" && v).map(String);
      if (parts.length) return parts.join(" | ").slice(0, 500);
    } catch { /* not JSON — fall through */ }
  }
  return t.slice(0, 500);
}

const ERR_LINE_RE = /^Error:|"level"\s*:\s*"(error|fatal|panic)"|\b(error|fatal)\b/i;

/**
 * Caddy's last error mentioning `domain` (case-insensitive), or — with no
 * domain — its last startup error. null when the logs hold none.
 */
export function lastStartupError(logs: string, domain?: string): string | null {
  const d = domain?.toLowerCase();
  const lines = logs.split("\n").filter((l) => l.trim() && ERR_LINE_RE.test(l) && (!d || l.toLowerCase().includes(d)));
  return lines.length ? summarize(lines[lines.length - 1]) : null;
}

export interface ContainerState { status: string; restarting: boolean; restartCount: number; startedAt: string }

/** Parse `docker inspect -f '{{.State.Status}}|{{.State.Restarting}}|{{.RestartCount}}|{{.State.StartedAt}}'`. */
export function parseState(out: string): ContainerState | null {
  const m = /^(\S+)\|(true|false)\|(\d+)\|(\S+)$/.exec(out.trim());
  return m ? { status: m[1], restarting: m[2] === "true", restartCount: Number(m[3]), startedAt: m[4] } : null;
}

export const STATE_TEMPLATE = "{{.State.Status}}|{{.State.Restarting}}|{{.RestartCount}}|{{.State.StartedAt}}";

export interface RepairReport {
  vm: string; container: string; dataDir: string; dryRun: boolean; allMesh: boolean;
  scan: ScanLine[]; restarted: string | null; state: ContainerState | null; remaining: string[]; startupErrors: { domain: string; error: string | null }[]; lastError: string | null;
}

/** Human report. Contains the phrase "nothing to repair" exactly when no cert needs moving. */
export function formatReport(r: RepairReport): string {
  const bad = r.scan.filter((s) => s.kind === "bad") as { cert: string }[];
  const moved = r.scan.filter((s) => s.kind === "moved") as { cert: string; to: string }[];
  const mesh = r.scan.find((s) => s.kind === "mesh") as { entries: number } | undefined;
  const meshMoved = r.scan.find((s) => s.kind === "mesh_moved") as { to: string } | undefined;
  const ok = (r.scan.find((s) => s.kind === "okn") as { n: number } | undefined)?.n ?? 0;
  const left = (r.scan.find((s) => s.kind === "timeout") as { left: number } | undefined)?.left ?? 0;
  const skipped = r.scan.filter((s) => s.kind === "skip") as { cert: string; why: string }[];
  const errs = r.scan.filter((s) => s.kind === "err") as { msg: string }[];
  const toRepair = bad.length > 0 || (r.allMesh && (mesh?.entries ?? 0) > 0);
  const out: string[] = [
    `caddy cert repair: ${r.container}@${r.vm}  (${r.dryRun ? "DRY RUN" : "LIVE"}${r.allMesh ? ", all_mesh" : ""})`,
    `/data host source: ${r.dataDir}`,
    `checked ${ok + bad.length} cert dirs: ${ok} match, ${bad.length} mismatched, ${skipped.length} skipped`,
  ];
  if (left) out.push(`  PARTIAL: time budget hit, ${left} cert dirs NOT checked; re-run to continue`);
  for (const b of bad) out.push(`  MISMATCH ${b.cert}${r.dryRun ? " (would move)" : ""}`);
  for (const s of skipped) out.push(`  skipped ${s.cert}: ${s.why}`);
  if (r.allMesh) out.push(`mesh dir: ${mesh?.entries ?? 0} entries${meshMoved ? ` -> moved to ${meshMoved.to}` : r.dryRun && mesh?.entries ? " (would move whole dir)" : ""}`);
  for (const m of moved) out.push(`  moved ${m.cert} -> ${m.to}`);
  for (const e of errs) out.push(`  ERROR ${e.msg}`);
  if (!toRepair && !errs.length && !left) out.push("nothing to repair: every cert key matches its certificate");
  else if (!toRepair && left) out.push("no mismatch among the checked certs (scan was partial)");
  else if (r.dryRun && toRepair) out.push("dry_run=true: nothing was moved or restarted. Re-run with dry_run=false to repair.");
  if (r.restarted) out.push(`restart: ${r.restarted}`);
  if (r.state) out.push(`container: ${r.state.status}${r.state.restarting ? " (restarting)" : ""}, restart count ${r.state.restartCount}`);
  if (r.restarted && !r.dryRun) return out.join("\n");
  out.push(r.remaining.length ? `remaining "private key does not match" log lines (${r.remaining.length}):` : 'no remaining "private key does not match" log lines');
  for (const l of r.remaining) out.push(`  ${l}`);
  for (const s of r.startupErrors) out.push(`last log error for ${s.domain}: ${s.error ?? "(none)"}`);
  out.push(`last startup error: ${r.lastError ?? "(none)"}`);
  return out.join("\n");
}
