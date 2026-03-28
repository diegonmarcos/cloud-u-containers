/**
 * SQLite persistence layer for C3.
 *
 * Stores: health check history, audit log, deploy log.
 * DB file: /app/data/c3.db (Docker volume) or ~/.local/share/c3/c3.db (local).
 *
 * Uses better-sqlite3 for synchronous, zero-config SQLite.
 */

import Database from "better-sqlite3";
import { existsSync, mkdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// ── DB Path ──────────────────────────────────────────────────────────────

const DB_DIR = process.env.C3_DATA_DIR
  ?? (existsSync("/app/data") ? "/app/data" : join(homedir(), ".local/share/c3"));

function ensureDir(dir: string) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

// ── Singleton ────────────────────────────────────────────────────────────

let _db: Database.Database | null = null;

export function getDb(): Database.Database {
  if (_db) return _db;

  ensureDir(DB_DIR);
  const dbPath = join(DB_DIR, "c3.db");

  _db = new Database(dbPath);
  _db.pragma("journal_mode = WAL");
  _db.pragma("busy_timeout = 5000");

  initSchema(_db);
  return _db;
}

// ── Schema ───────────────────────────────────────────────────────────────

function initSchema(db: Database.Database) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS health_checks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      vm TEXT NOT NULL,
      tier INTEGER NOT NULL,
      reachable INTEGER NOT NULL,
      ssh_ok INTEGER,
      latency_ms INTEGER,
      disk_percent TEXT,
      mem_used TEXT,
      containers_up INTEGER,
      containers_total INTEGER,
      error TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_health_ts ON health_checks(ts);
    CREATE INDEX IF NOT EXISTS idx_health_vm ON health_checks(vm);

    CREATE TABLE IF NOT EXISTS audit_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      tool TEXT NOT NULL,
      target TEXT NOT NULL,
      result TEXT NOT NULL,
      source TEXT DEFAULT 'mcp'
    );

    CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);
    CREATE INDEX IF NOT EXISTS idx_audit_tool ON audit_log(tool);

    CREATE TABLE IF NOT EXISTS deploy_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      service TEXT NOT NULL,
      step TEXT NOT NULL,
      success INTEGER NOT NULL,
      duration_ms INTEGER,
      output TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_deploy_ts ON deploy_log(ts);
    CREATE INDEX IF NOT EXISTS idx_deploy_svc ON deploy_log(service);

    CREATE TABLE IF NOT EXISTS alert_state (
      vm TEXT PRIMARY KEY,
      last_status TEXT NOT NULL DEFAULT 'ok',
      last_change TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      notified INTEGER NOT NULL DEFAULT 0
    );
  `);
}

// ── Health Checks ────────────────────────────────────────────────────────

export interface HealthRecord {
  vm: string;
  tier: number;
  reachable: boolean;
  sshOk?: boolean;
  latencyMs?: number;
  diskPercent?: string;
  memUsed?: string;
  containersUp?: number;
  containersTotal?: number;
  error?: string;
}

export function recordHealthCheck(record: HealthRecord): void {
  const db = getDb();
  db.prepare(`
    INSERT INTO health_checks (vm, tier, reachable, ssh_ok, latency_ms, disk_percent, mem_used, containers_up, containers_total, error)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    record.vm,
    record.tier,
    record.reachable ? 1 : 0,
    record.sshOk != null ? (record.sshOk ? 1 : 0) : null,
    record.latencyMs ?? null,
    record.diskPercent ?? null,
    record.memUsed ?? null,
    record.containersUp ?? null,
    record.containersTotal ?? null,
    record.error ?? null,
  );
}

export interface HealthHistoryQuery {
  vm?: string;
  since?: string;
  limit?: number;
}

export interface HealthHistoryRow {
  id: number;
  ts: string;
  vm: string;
  tier: number;
  reachable: boolean;
  ssh_ok: boolean | null;
  latency_ms: number | null;
  disk_percent: string | null;
  mem_used: string | null;
  containers_up: number | null;
  containers_total: number | null;
  error: string | null;
}

export function getHealthHistory(query: HealthHistoryQuery = {}): HealthHistoryRow[] {
  const db = getDb();
  const conditions: string[] = [];
  const params: unknown[] = [];

  if (query.vm) {
    conditions.push("vm = ?");
    params.push(query.vm);
  }
  if (query.since) {
    conditions.push("ts >= ?");
    params.push(query.since);
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
  const limit = query.limit ?? 100;

  const rows = db.prepare(
    `SELECT * FROM health_checks ${where} ORDER BY ts DESC LIMIT ?`
  ).all(...params, limit) as Array<Record<string, unknown>>;

  return rows.map((r) => ({
    id: r.id as number,
    ts: r.ts as string,
    vm: r.vm as string,
    tier: r.tier as number,
    reachable: r.reachable === 1,
    ssh_ok: r.ssh_ok != null ? r.ssh_ok === 1 : null,
    latency_ms: r.latency_ms as number | null,
    disk_percent: r.disk_percent as string | null,
    mem_used: r.mem_used as string | null,
    containers_up: r.containers_up as number | null,
    containers_total: r.containers_total as number | null,
    error: r.error as string | null,
  }));
}

export function getUptimeReport(vm?: string, hours = 24): {
  vm: string;
  checks: number;
  up: number;
  down: number;
  uptimePercent: number;
}[] {
  const db = getDb();
  const since = new Date(Date.now() - hours * 3600_000).toISOString();

  const sql = vm
    ? `SELECT vm, COUNT(*) as total, SUM(reachable) as up FROM health_checks WHERE ts >= ? AND vm = ? GROUP BY vm`
    : `SELECT vm, COUNT(*) as total, SUM(reachable) as up FROM health_checks WHERE ts >= ? GROUP BY vm`;

  const params: unknown[] = vm ? [since, vm] : [since];
  const rows = db.prepare(sql).all(...params) as Array<Record<string, unknown>>;

  return rows.map((r) => {
    const total = r.total as number;
    const up = r.up as number;
    return {
      vm: r.vm as string,
      checks: total,
      up,
      down: total - up,
      uptimePercent: total > 0 ? Math.round((up / total) * 10000) / 100 : 0,
    };
  });
}

// ── Audit Log ────────────────────────────────────────────────────────────

export function recordAudit(tool: string, target: string, result: string, source = "mcp"): void {
  const db = getDb();
  db.prepare(
    `INSERT INTO audit_log (tool, target, result, source) VALUES (?, ?, ?, ?)`
  ).run(tool, target, result, source);
}

export interface AuditQuery {
  tool?: string;
  since?: string;
  limit?: number;
}

export interface AuditRow {
  id: number;
  ts: string;
  tool: string;
  target: string;
  result: string;
  source: string;
}

export function getAuditLog(query: AuditQuery = {}): AuditRow[] {
  const db = getDb();
  const conditions: string[] = [];
  const params: unknown[] = [];

  if (query.tool) {
    conditions.push("tool = ?");
    params.push(query.tool);
  }
  if (query.since) {
    conditions.push("ts >= ?");
    params.push(query.since);
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
  const limit = query.limit ?? 100;

  return db.prepare(
    `SELECT * FROM audit_log ${where} ORDER BY ts DESC LIMIT ?`
  ).all(...params, limit) as AuditRow[];
}

// ── Deploy Log ───────────────────────────────────────────────────────────

export function recordDeploy(
  service: string,
  step: string,
  success: boolean,
  durationMs?: number,
  output?: string,
): void {
  const db = getDb();
  db.prepare(
    `INSERT INTO deploy_log (service, step, success, duration_ms, output) VALUES (?, ?, ?, ?, ?)`
  ).run(service, step, success ? 1 : 0, durationMs ?? null, output?.slice(-2000) ?? null);
}

export interface DeployQuery {
  service?: string;
  since?: string;
  limit?: number;
}

export interface DeployRow {
  id: number;
  ts: string;
  service: string;
  step: string;
  success: boolean;
  duration_ms: number | null;
  output: string | null;
}

export function getDeployHistory(query: DeployQuery = {}): DeployRow[] {
  const db = getDb();
  const conditions: string[] = [];
  const params: unknown[] = [];

  if (query.service) {
    conditions.push("service = ?");
    params.push(query.service);
  }
  if (query.since) {
    conditions.push("ts >= ?");
    params.push(query.since);
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
  const limit = query.limit ?? 50;

  const rows = db.prepare(
    `SELECT * FROM deploy_log ${where} ORDER BY ts DESC LIMIT ?`
  ).all(...params, limit) as Array<Record<string, unknown>>;

  return rows.map((r) => ({
    id: r.id as number,
    ts: r.ts as string,
    service: r.service as string,
    step: r.step as string,
    success: r.success === 1,
    duration_ms: r.duration_ms as number | null,
    output: r.output as string | null,
  }));
}

// ── Alert State ──────────────────────────────────────────────────────────

export function getAlertState(vm: string): { lastStatus: string; lastChange: string; notified: boolean } | null {
  const db = getDb();
  const row = db.prepare(`SELECT * FROM alert_state WHERE vm = ?`).get(vm) as Record<string, unknown> | undefined;
  if (!row) return null;
  return {
    lastStatus: row.last_status as string,
    lastChange: row.last_change as string,
    notified: row.notified === 1,
  };
}

export function updateAlertState(vm: string, status: string, notified: boolean): void {
  const db = getDb();
  db.prepare(`
    INSERT INTO alert_state (vm, last_status, last_change, notified)
    VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ?)
    ON CONFLICT(vm) DO UPDATE SET
      last_status = excluded.last_status,
      last_change = CASE WHEN last_status != excluded.last_status THEN excluded.last_change ELSE last_change END,
      notified = excluded.notified
  `).run(vm, status, notified ? 1 : 0);
}

// ── Cleanup ──────────────────────────────────────────────────────────────

export function pruneOldRecords(daysToKeep = 30): { healthDeleted: number; auditDeleted: number; deployDeleted: number } {
  const db = getDb();
  const cutoff = new Date(Date.now() - daysToKeep * 86400_000).toISOString();

  const h = db.prepare("DELETE FROM health_checks WHERE ts < ?").run(cutoff);
  const a = db.prepare("DELETE FROM audit_log WHERE ts < ?").run(cutoff);
  const d = db.prepare("DELETE FROM deploy_log WHERE ts < ?").run(cutoff);

  return {
    healthDeleted: h.changes,
    auditDeleted: a.changes,
    deployDeleted: d.changes,
  };
}
