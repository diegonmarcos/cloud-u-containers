# v0.4.0 Implementation Plan — Reliability & Operations

## Task 1: Add prom-client and create metrics module

Install `prom-client` in `packages/api`:

```bash
cd packages/api && npm install prom-client
```

Create `packages/api/src/metrics.ts`:

```typescript
import client from 'prom-client';

// Collect default Node.js metrics (GC, memory, event loop)
client.collectDefaultMetrics();

export const registry = client.register;

// --- HTTP metrics ---
export const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'] as const,
});

export const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route'] as const,
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 5, 10],
});

// --- Application metrics ---
export const actorRunsTotal = new client.Counter({
  name: 'actor_runs_total',
  help: 'Total actor runs by final status',
  labelNames: ['status'] as const,
});

export const actorRunsActive = new client.Gauge({
  name: 'actor_runs_active',
  help: 'Currently active actor runs',
});

export const webhookDeliveriesTotal = new client.Counter({
  name: 'webhook_deliveries_total',
  help: 'Total webhook deliveries by status',
  labelNames: ['status'] as const,
});

export const schedulerActiveJobs = new client.Gauge({
  name: 'scheduler_active_jobs',
  help: 'Number of active cron scheduler jobs',
});

export const dbPoolActive = new client.Gauge({
  name: 'db_pool_active_connections',
  help: 'Active database pool connections',
});

export const dbPoolIdle = new client.Gauge({
  name: 'db_pool_idle_connections',
  help: 'Idle database pool connections',
});
```

## Task 2: Wire metrics into API server

In `packages/api/src/index.ts`:

Add import:

```typescript
import { registry, httpRequestsTotal, httpRequestDuration } from './metrics.js';
```

Add Fastify hooks after `app.setErrorHandler(...)`:

```typescript
// Metrics collection hooks
app.addHook('onRequest', (request, _reply, done) => {
  (request as any).__startTime = process.hrtime.bigint();
  done();
});

app.addHook('onResponse', (request, reply, done) => {
  const startTime = (request as any).__startTime as bigint | undefined;
  const route = request.routeOptions?.url ?? request.url;
  const method = request.method;
  const statusCode = String(reply.statusCode);

  httpRequestsTotal.inc({ method, route, status_code: statusCode });

  if (startTime) {
    const duration = Number(process.hrtime.bigint() - startTime) / 1e9;
    httpRequestDuration.observe({ method, route }, duration);
  }

  done();
});
```

Add `/metrics` endpoint after `/health`:

```typescript
app.get('/metrics', async (_request, reply) => {
  reply.header('Content-Type', registry.contentType);
  return registry.metrics();
});
```

## Task 3: Create health check module

Create `packages/api/src/health.ts`:

```typescript
import type { FastifyInstance } from 'fastify';
import { pool } from './db/index.js';
import { redis } from './storage/redis.js';
import { s3 } from './storage/s3.js';
import { config } from './config.js';
import { getActiveScheduleCount } from './scheduler.js';
import { HeadBucketCommand } from '@aws-sdk/client-s3';

interface CheckResult {
  status: 'ok' | 'error';
  latencyMs?: number;
  error?: string;
}

async function checkWithTimeout(
  name: string,
  fn: () => Promise<void>,
  timeoutMs = 3000
): Promise<CheckResult> {
  const start = Date.now();
  try {
    await Promise.race([
      fn(),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error(`${name} health check timed out`)), timeoutMs)
      ),
    ]);
    return { status: 'ok', latencyMs: Date.now() - start };
  } catch (err) {
    return { status: 'error', latencyMs: Date.now() - start, error: (err as Error).message };
  }
}

export function registerHealthRoutes(app: FastifyInstance): void {
  // Liveness — is the process alive?
  app.get('/health/live', () => ({ status: 'ok' }));

  // Readiness — can we serve traffic?
  app.get('/health/ready', async (_request, reply) => {
    const [db, redisCheck, s3Check] = await Promise.all([
      checkWithTimeout('db', async () => {
        await pool.query('SELECT 1');
      }),
      checkWithTimeout('redis', async () => {
        await redis.ping();
      }),
      checkWithTimeout('s3', async () => {
        await s3.send(new HeadBucketCommand({ Bucket: config.s3Bucket }));
      }),
    ]);

    const checks = { db, redis: redisCheck, s3: s3Check };
    const allOk = Object.values(checks).every((c) => c.status === 'ok');

    const body = {
      status: allOk ? 'ok' : 'degraded',
      checks,
      schedulerJobs: getActiveScheduleCount(),
    };

    return reply.status(allOk ? 200 : 503).send(body);
  });
}
```

Wire in `index.ts` — import `registerHealthRoutes` and call it after route registration:

```typescript
import { registerHealthRoutes } from './health.js';
// ... after route registration, before /health endpoint
registerHealthRoutes(app);
```

## Task 4: Graceful shutdown for API server

In `packages/api/src/index.ts`, replace `void start()` with a shutdown-aware version:

```typescript
async function start() {
  await initDatabase();
  await initS3();
  await initRedis();
  await setupAdminUser();
  await initScheduler();

  await app.listen({ port: config.port, host: '0.0.0.0' });
  console.log(`Server on http://0.0.0.0:${String(config.port)}`);
}

function setupGracefulShutdown(): void {
  const shutdownTimeoutSecs = parseInt(process.env.SHUTDOWN_TIMEOUT_SECS ?? '60', 10);
  let shuttingDown = false;

  const shutdown = async (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(
      `Received ${signal}, shutting down gracefully (timeout: ${shutdownTimeoutSecs}s)...`
    );

    const forceExit = setTimeout(() => {
      console.error('Shutdown timeout exceeded, forcing exit');
      process.exit(1);
    }, shutdownTimeoutSecs * 1000);

    try {
      // 1. Stop scheduler
      const { unregisterAllSchedules } = await import('./scheduler.js');
      unregisterAllSchedules();

      // 2. Close HTTP server (drain in-flight requests)
      await app.close();

      // 3. Close Redis
      const { redis } = await import('./storage/redis.js');
      await redis.quit();

      // 4. Close database pool
      const { pool } = await import('./db/index.js');
      await pool.end();

      console.log('Graceful shutdown complete');
      clearTimeout(forceExit);
      process.exit(0);
    } catch (err) {
      console.error('Error during shutdown:', err);
      clearTimeout(forceExit);
      process.exit(1);
    }
  };

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}

setupGracefulShutdown();
void start();
export { app };
```

Add `unregisterAllSchedules` to `packages/api/src/scheduler.ts`:

```typescript
export function unregisterAllSchedules(): void {
  for (const [id, task] of activeJobs) {
    void task.stop();
    activeJobs.delete(id);
  }
}
```

## Task 5: Graceful shutdown for runner

Replace signal handlers in `packages/runner/src/index.ts`:

```typescript
import { config } from './config.js';
import { checkDocker, listRunningContainers } from './docker.js';
import { initJobQueue, startProcessing, stopProcessing, getActiveRunCount } from './queue.js';

async function main() {
  // ... existing startup code unchanged ...

  // Start processing runs
  console.log('Starting run processor...');
  await startProcessing();
}

function setupGracefulShutdown(): void {
  const shutdownTimeoutSecs = parseInt(process.env.SHUTDOWN_TIMEOUT_SECS ?? '60', 10);
  let shuttingDown = false;

  const shutdown = async (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`Received ${signal}, stopping run processor...`);

    // Signal queue to stop accepting new runs
    stopProcessing();

    const forceExit = setTimeout(() => {
      const active = getActiveRunCount();
      console.error(`Shutdown timeout exceeded with ${active} active runs, forcing exit`);
      process.exit(1);
    }, shutdownTimeoutSecs * 1000);

    // Wait for active runs to finish
    const checkInterval = setInterval(() => {
      const active = getActiveRunCount();
      if (active === 0) {
        clearInterval(checkInterval);
        clearTimeout(forceExit);
        console.log('All runs completed, exiting');
        process.exit(0);
      }
      console.log(`Waiting for ${active} active run(s) to finish...`);
    }, 2000);
  };

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}

setupGracefulShutdown();
main().catch((err: unknown) => {
  console.error('Runner failed:', err);
  process.exit(1);
});
```

In `packages/runner/src/queue.ts`, add exports:

```typescript
let shuttingDown = false;

export function stopProcessing(): void {
  shuttingDown = true;
}

export function getActiveRunCount(): number {
  return activeRuns;
}
```

Modify `startProcessing()` to check `shuttingDown`:

```typescript
export async function startProcessing(): Promise<void> {
  // webhook retry loop also checks shuttingDown
  while (!shuttingDown) {
    await processNextRun();
    await sleep(1000);
  }
}
```

Modify `processNextRun()` to check `shuttingDown`:

```typescript
async function processNextRun(): Promise<void> {
  if (shuttingDown || isProcessing || activeRuns >= config.maxConcurrentRuns) {
    return;
  }
  // ... rest unchanged
}
```

## Task 6: Run history cleanup script

Create `scripts/cleanup-old-data.ts`:

Uses direct pg Pool and S3Client to delete expired runs, associated storages (datasets, KV stores, request queues from both DB and S3), and old webhook deliveries.

Features:

- `--retention-days N` (default 90) for runs
- `--webhook-retention-days N` (default 30)
- `--batch-size N` (default 100)
- `--dry-run` flag
- Summary output at end

Reads `DATABASE_URL`, `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`, `S3_REGION` from env.

Add to root `package.json` scripts:

```json
"cleanup": "npx tsx scripts/cleanup-old-data.ts"
```

## Task 7: Database backup scripts

Create three scripts using `execFileSync` (not `execSync`) to prevent command injection:

**`scripts/backup-db.ts`**:

- Uses `execFileSync('pg_dump', ['--format=custom', '-f', filepath, databaseUrl])`
- `--output` flag for directory (default `./backups/`)
- Names: `crawlee-cloud-backup-YYYY-MM-DDTHH-MM-SS.dump`

**`scripts/restore-db.ts`**:

- Uses `execFileSync('pg_restore', ['--clean', '--if-exists', '--dbname=' + databaseUrl, backupFile])`
- Interactive confirmation prompt before proceeding

**`scripts/list-backups.ts`**:

- Lists `.dump` files with size and date
- `--dir` flag for directory

Add to root `package.json` scripts:

```json
"backup:create": "npx tsx scripts/backup-db.ts",
"backup:restore": "npx tsx scripts/restore-db.ts",
"backup:list": "npx tsx scripts/list-backups.ts"
```

## Task 8: Update docs-drift skip list

In `scripts/check-docs-drift.ts`, add `/health` and `/metrics` to `skipRoutePrefixes`:

```typescript
const skipRoutePrefixes = [
  '/v2/auth/',
  '/users/',
  '/actor-runs/:runId/logs/stream',
  '/webhooks',
  '/schedules',
  '/health',
  '/metrics',
];
```

## Task 9: Tests

Create `packages/api/test/health.test.ts`:

- Test `GET /health/live` returns 200
- Test `GET /health/ready` returns 200 with all checks passing (mock pool.query, redis.ping, s3.send)
- Test `GET /health/ready` returns 503 when DB is down (mock pool.query to throw)

Create `packages/api/test/metrics.test.ts`:

- Test `GET /metrics` returns Prometheus text format
- Test that HTTP hooks increment counters (verify via registry output)

## Task 10: Final verification

- Typecheck all packages: `npm run typecheck`
- Run all tests: `npm test --workspace=@crawlee-cloud/api -- --run`
- Lint check on new files
- Update ROADMAP.md to mark v0.4.0 complete

## Task Order & Dependencies

```
Task 1 (metrics module) ─┐
                          ├─ Task 2 (wire metrics)
Task 3 (health module) ──┤
                          ├─ Task 4 (API shutdown) ──┐
                          │                          ├─ Task 9 (tests)
Task 5 (runner shutdown) ─┘                          │
Task 6 (cleanup script) ──────────────────────────── │
Task 7 (backup scripts) ──────────────────────────── │
Task 8 (docs drift) ──────────────────────────────── ├─ Task 10 (verify)
```

Tasks 1, 3, 5, 6, 7, 8 are independent and can run in parallel.
Task 2 depends on Task 1.
Task 4 depends on Task 3 (health module).
Task 9 depends on Tasks 2, 3, 4, 5.
Task 10 depends on all.
