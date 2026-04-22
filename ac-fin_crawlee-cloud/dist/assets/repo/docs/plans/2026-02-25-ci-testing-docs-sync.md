# CI Pipeline, Integration Tests & Docs Sync — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add CI workflows, integration tests against real services, and a docs drift checker so the platform catches regressions and stale documentation automatically.

**Architecture:** Three GitHub Actions workflows (ci.yml, docs-check.yml, existing publish-cli.yml). Integration tests use a shared Fastify test helper connected to PostgreSQL/Redis/MinIO service containers. A TypeScript script extracts route/CLI/env-var definitions from source code and compares them against the docs repo markdown files.

**Tech Stack:** GitHub Actions, Vitest, Fastify, PostgreSQL 16, Redis 7, MinIO, TypeScript (tsx for scripts)

---

## Task 1: Create CI workflow file

**Files:**

- Create: `.github/workflows/ci.yml`

**Step 1: Write the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint-typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npm run typecheck

  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run build
      - run: npx vitest run --project api --project runner --project cli

  integration-tests:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: crawlee_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U test"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 5
      redis:
        image: redis:7-alpine
        ports:
          - 6379:6379
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 5
      minio:
        image: minio/minio:latest
        ports:
          - 9000:9000
        env:
          MINIO_ROOT_USER: minioadmin
          MINIO_ROOT_PASSWORD: minioadmin
        options: >-
          --health-cmd "curl -f http://localhost:9000/minio/health/live || exit 1"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run build
      - name: Create MinIO bucket
        run: |
          curl -s https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
          chmod +x /usr/local/bin/mc
          mc alias set ci http://localhost:9000 minioadmin minioadmin
          mc mb ci/crawlee-test --ignore-existing
      - name: Run integration tests
        env:
          DATABASE_URL: postgresql://test:test@localhost:5432/crawlee_test
          REDIS_URL: redis://localhost:6379
          S3_ENDPOINT: http://localhost:9000
          S3_ACCESS_KEY: minioadmin
          S3_SECRET_KEY: minioadmin
          S3_BUCKET: crawlee-test
          S3_REGION: us-east-1
          S3_FORCE_PATH_STYLE: 'true'
          API_SECRET: integration-test-secret-at-least-32-characters
          CORS_ORIGINS: http://localhost:3000
          NODE_ENV: test
        run: npx vitest run --project integration
```

**Step 2: Verify YAML is valid**

Run: `node -e "const y=require('yaml'); y.parse(require('fs').readFileSync('.github/workflows/ci.yml','utf8')); console.log('Valid YAML')"`

**Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add CI workflow with lint, unit tests, and integration tests"
```

---

## Task 2: Add integration test vitest project to workspace

**Files:**

- Modify: `vitest.workspace.ts`

**Step 1: Add integration project**

Update `vitest.workspace.ts` to:

```typescript
import { defineWorkspace } from 'vitest/config';

export default defineWorkspace([
  'packages/cli',
  'packages/api',
  'packages/runner',
  {
    test: {
      name: 'integration',
      root: 'packages/api',
      include: ['test/integration/**/*.int.test.ts'],
      testTimeout: 30_000,
      hookTimeout: 30_000,
    },
  },
]);
```

**Step 2: Verify workspace config loads**

Run: `npx vitest list --project integration 2>&1 | head -5`

Expected: No errors (may show "no test files" — that's fine, we haven't written tests yet).

**Step 3: Commit**

```bash
git add vitest.workspace.ts
git commit -m "ci: add integration test project to vitest workspace"
```

---

## Task 3: Create integration test helper

**Files:**

- Create: `packages/api/test/integration/setup.ts`

This helper builds a real Fastify app wired to the service containers. Every integration test file imports it.

**Step 1: Write the setup helper**

Create `packages/api/test/integration/setup.ts`:

```typescript
/**
 * Integration test setup — builds a real Fastify app connected to
 * PostgreSQL, Redis, and MinIO from environment variables.
 *
 * Usage in test files:
 *   import { createTestApp, runMigrations, createTestUser } from './setup.js';
 */
import Fastify, { type FastifyInstance } from 'fastify';
import { S3Client, CreateBucketCommand, HeadBucketCommand } from '@aws-sdk/client-s3';

// Re-export config so tests can read env
export const TEST_CONFIG = {
  databaseUrl: process.env.DATABASE_URL || 'postgresql://test:test@localhost:5432/crawlee_test',
  redisUrl: process.env.REDIS_URL || 'redis://localhost:6379',
  s3Endpoint: process.env.S3_ENDPOINT || 'http://localhost:9000',
  s3AccessKey: process.env.S3_ACCESS_KEY || 'minioadmin',
  s3SecretKey: process.env.S3_SECRET_KEY || 'minioadmin',
  s3Bucket: process.env.S3_BUCKET || 'crawlee-test',
  s3Region: process.env.S3_REGION || 'us-east-1',
  apiSecret: process.env.API_SECRET || 'integration-test-secret-at-least-32-characters',
};

/**
 * Build a Fastify instance with all routes registered,
 * backed by real database/redis/s3.
 */
export async function createTestApp(): Promise<FastifyInstance> {
  // Set env vars that the app's config.ts reads
  process.env.DATABASE_URL = TEST_CONFIG.databaseUrl;
  process.env.REDIS_URL = TEST_CONFIG.redisUrl;
  process.env.S3_ENDPOINT = TEST_CONFIG.s3Endpoint;
  process.env.S3_ACCESS_KEY = TEST_CONFIG.s3AccessKey;
  process.env.S3_SECRET_KEY = TEST_CONFIG.s3SecretKey;
  process.env.S3_BUCKET = TEST_CONFIG.s3Bucket;
  process.env.S3_REGION = TEST_CONFIG.s3Region;
  process.env.S3_FORCE_PATH_STYLE = 'true';
  process.env.API_SECRET = TEST_CONFIG.apiSecret;
  process.env.CORS_ORIGINS = 'http://localhost:3000';
  process.env.NODE_ENV = 'test';

  // Dynamic imports so env vars are read fresh
  const { initDatabase } = await import('../../src/db/index.js');
  const { initS3 } = await import('../../src/storage/s3.js');
  const { initRedis } = await import('../../src/storage/redis.js');
  const { authRoutes } = await import('../../src/routes/auth.js');
  const { actorsRoutes } = await import('../../src/routes/actors.js');
  const { runsRoutes } = await import('../../src/routes/runs.js');
  const { datasetsRoutes } = await import('../../src/routes/datasets.js');
  const { keyValueStoresRoutes } = await import('../../src/routes/key-value-stores.js');
  const { requestQueuesRoutes } = await import('../../src/routes/request-queues.js');
  const { logsRoutes } = await import('../../src/routes/logs.js');

  await initDatabase();
  await initS3();
  await initRedis();

  const app = Fastify({ logger: false });

  await authRoutes(app);
  await app.register(actorsRoutes, { prefix: '/v2' });
  await app.register(runsRoutes, { prefix: '/v2' });
  await app.register(datasetsRoutes, { prefix: '/v2' });
  await app.register(keyValueStoresRoutes, { prefix: '/v2' });
  await app.register(requestQueuesRoutes, { prefix: '/v2' });
  await app.register(logsRoutes, { prefix: '/v2' });

  await app.ready();
  return app;
}

/**
 * Run database migrations.
 */
export async function runMigrations(): Promise<void> {
  const { migrate } = await import('../../src/db/migrate.js');
  await migrate();
}

/**
 * Create a test user and return a valid JWT token.
 */
export async function createTestUser(
  email = 'test@integration.local',
  password = 'testpassword123'
): Promise<{ userId: string; token: string }> {
  const { hashPassword } = await import('../../src/auth/index.js');
  const { pool } = await import('../../src/db/index.js');
  const { nanoid } = await import('nanoid');
  const { createToken } = await import('../../src/auth/index.js');

  const userId = nanoid();
  const passwordHash = await hashPassword(password);

  await pool.query(
    `INSERT INTO users (id, email, password_hash, role) VALUES ($1, $2, $3, 'user')
     ON CONFLICT (email) DO UPDATE SET password_hash = $3 RETURNING id`,
    [userId, email, passwordHash]
  );

  const token = createToken({ userId, email, role: 'user' });
  return { userId, token };
}

/**
 * Delete all rows from test tables (order matters for foreign keys).
 */
export async function cleanDatabase(): Promise<void> {
  const { pool } = await import('../../src/db/index.js');
  await pool.query(`
    DELETE FROM requests;
    DELETE FROM request_queues;
    DELETE FROM key_value_stores;
    DELETE FROM datasets;
    DELETE FROM runs;
    DELETE FROM actor_builds;
    DELETE FROM actor_versions;
    DELETE FROM actors;
    DELETE FROM api_keys;
    DELETE FROM webhooks;
    DELETE FROM users;
  `);
}

/**
 * Ensure the S3 test bucket exists.
 */
export async function ensureS3Bucket(): Promise<void> {
  const s3 = new S3Client({
    endpoint: TEST_CONFIG.s3Endpoint,
    region: TEST_CONFIG.s3Region,
    credentials: {
      accessKeyId: TEST_CONFIG.s3AccessKey,
      secretAccessKey: TEST_CONFIG.s3SecretKey,
    },
    forcePathStyle: true,
  });

  try {
    await s3.send(new HeadBucketCommand({ Bucket: TEST_CONFIG.s3Bucket }));
  } catch {
    await s3.send(new CreateBucketCommand({ Bucket: TEST_CONFIG.s3Bucket }));
  }
}
```

**Step 2: Verify the file compiles**

Run: `npx tsc --noEmit -p packages/api/tsconfig.json 2>&1 | head -20`

Expected: No errors related to setup.ts.

**Step 3: Commit**

```bash
git add packages/api/test/integration/setup.ts
git commit -m "test: add integration test setup helper"
```

---

## Task 4: Write datasets integration test

**Files:**

- Create: `packages/api/test/integration/datasets.int.test.ts`

**Step 1: Write the test**

```typescript
import { describe, it, expect, beforeAll, afterEach, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import {
  createTestApp,
  runMigrations,
  createTestUser,
  cleanDatabase,
  ensureS3Bucket,
} from './setup.js';

describe('Datasets (integration)', () => {
  let app: FastifyInstance;
  let token: string;

  beforeAll(async () => {
    await ensureS3Bucket();
    app = await createTestApp();
    await runMigrations();
    const user = await createTestUser();
    token = user.token;
  });

  afterEach(async () => {
    await cleanDatabase();
    // Re-create user after clean
    const user = await createTestUser();
    token = user.token;
  });

  afterAll(async () => {
    await app.close();
  });

  it('creates a dataset, pushes items, and retrieves them', async () => {
    // Create
    const create = await app.inject({
      method: 'POST',
      url: '/v2/datasets',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'test-ds' },
    });
    expect(create.statusCode).toBe(201);
    const datasetId = create.json().data.id;

    // Push items
    const push = await app.inject({
      method: 'POST',
      url: `/v2/datasets/${datasetId}/items`,
      headers: { authorization: `Bearer ${token}` },
      payload: [{ title: 'A' }, { title: 'B' }, { title: 'C' }],
    });
    expect(push.statusCode).toBe(201);

    // Get items
    const items = await app.inject({
      method: 'GET',
      url: `/v2/datasets/${datasetId}/items`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(items.statusCode).toBe(200);
    expect(items.json()).toHaveLength(3);
    expect(items.json()[0]).toEqual({ title: 'A' });
  });

  it('respects pagination offset and limit', async () => {
    const create = await app.inject({
      method: 'POST',
      url: '/v2/datasets',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'paged' },
    });
    const id = create.json().data.id;

    // Push 5 items
    await app.inject({
      method: 'POST',
      url: `/v2/datasets/${id}/items`,
      headers: { authorization: `Bearer ${token}` },
      payload: [{ n: 1 }, { n: 2 }, { n: 3 }, { n: 4 }, { n: 5 }],
    });

    const page = await app.inject({
      method: 'GET',
      url: `/v2/datasets/${id}/items?offset=2&limit=2`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(page.statusCode).toBe(200);
    expect(page.json()).toHaveLength(2);
    expect(page.json()[0]).toEqual({ n: 3 });
  });

  it('isolates datasets between users (IDOR)', async () => {
    // User A creates a dataset
    await app.inject({
      method: 'POST',
      url: '/v2/datasets',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'private-ds' },
    });

    // User B
    const userB = await createTestUser('userb@test.local', 'password123');

    const list = await app.inject({
      method: 'GET',
      url: '/v2/datasets',
      headers: { authorization: `Bearer ${userB.token}` },
    });
    expect(list.json().data.items).toHaveLength(0);
  });
});
```

**Step 2: Run the test locally (requires services running)**

Run: `npx vitest run --project integration packages/api/test/integration/datasets.int.test.ts`

Expected: Tests pass if docker services are running (`npm run docker:dev`). In CI, service containers provide them.

**Step 3: Commit**

```bash
git add packages/api/test/integration/datasets.int.test.ts
git commit -m "test: add datasets integration test"
```

---

## Task 5: Write key-value stores integration test

**Files:**

- Create: `packages/api/test/integration/key-value-stores.int.test.ts`

**Step 1: Write the test**

```typescript
import { describe, it, expect, beforeAll, afterEach, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import {
  createTestApp,
  runMigrations,
  createTestUser,
  cleanDatabase,
  ensureS3Bucket,
} from './setup.js';

describe('Key-Value Stores (integration)', () => {
  let app: FastifyInstance;
  let token: string;

  beforeAll(async () => {
    await ensureS3Bucket();
    app = await createTestApp();
    await runMigrations();
    const user = await createTestUser();
    token = user.token;
  });

  afterEach(async () => {
    await cleanDatabase();
    const user = await createTestUser();
    token = user.token;
  });

  afterAll(async () => {
    await app.close();
  });

  it('creates a store, sets a JSON value, and gets it back', async () => {
    const create = await app.inject({
      method: 'POST',
      url: '/v2/key-value-stores',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'test-kv' },
    });
    expect(create.statusCode).toBe(201);
    const storeId = create.json().data.id;

    // Set value
    const put = await app.inject({
      method: 'PUT',
      url: `/v2/key-value-stores/${storeId}/records/OUTPUT`,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      payload: JSON.stringify({ result: 'hello' }),
    });
    expect(put.statusCode).toBe(200);

    // Get value
    const get = await app.inject({
      method: 'GET',
      url: `/v2/key-value-stores/${storeId}/records/OUTPUT`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(get.statusCode).toBe(200);
    expect(get.json()).toEqual({ result: 'hello' });
  });

  it('handles binary data round-trip', async () => {
    const create = await app.inject({
      method: 'POST',
      url: '/v2/key-value-stores',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'binary-kv' },
    });
    const storeId = create.json().data.id;

    const binaryData = Buffer.from([0x00, 0x01, 0x02, 0xff]);

    await app.inject({
      method: 'PUT',
      url: `/v2/key-value-stores/${storeId}/records/BINARY`,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/octet-stream',
      },
      payload: binaryData,
    });

    const get = await app.inject({
      method: 'GET',
      url: `/v2/key-value-stores/${storeId}/records/BINARY`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(get.statusCode).toBe(200);
    expect(Buffer.from(get.rawPayload)).toEqual(binaryData);
  });
});
```

**Step 2: Run the test**

Run: `npx vitest run --project integration packages/api/test/integration/key-value-stores.int.test.ts`

**Step 3: Commit**

```bash
git add packages/api/test/integration/key-value-stores.int.test.ts
git commit -m "test: add key-value stores integration test"
```

---

## Task 6: Write request queues integration test

**Files:**

- Create: `packages/api/test/integration/request-queues.int.test.ts`

**Step 1: Write the test**

```typescript
import { describe, it, expect, beforeAll, afterEach, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import {
  createTestApp,
  runMigrations,
  createTestUser,
  cleanDatabase,
  ensureS3Bucket,
} from './setup.js';

describe('Request Queues (integration)', () => {
  let app: FastifyInstance;
  let token: string;

  beforeAll(async () => {
    await ensureS3Bucket();
    app = await createTestApp();
    await runMigrations();
    const user = await createTestUser();
    token = user.token;
  });

  afterEach(async () => {
    await cleanDatabase();
    const user = await createTestUser();
    token = user.token;
  });

  afterAll(async () => {
    await app.close();
  });

  it('creates queue, adds requests, locks and processes them', async () => {
    // Create queue
    const create = await app.inject({
      method: 'POST',
      url: '/v2/request-queues',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'crawl-queue' },
    });
    expect(create.statusCode).toBe(201);
    const queueId = create.json().data.id;

    // Add requests
    await app.inject({
      method: 'POST',
      url: `/v2/request-queues/${queueId}/requests`,
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://example.com/page1', uniqueKey: 'page1' },
    });
    await app.inject({
      method: 'POST',
      url: `/v2/request-queues/${queueId}/requests`,
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://example.com/page2', uniqueKey: 'page2' },
    });

    // Lock head
    const head = await app.inject({
      method: 'POST',
      url: `/v2/request-queues/${queueId}/head/lock`,
      headers: { authorization: `Bearer ${token}` },
      payload: { lockSecs: 60, limit: 10 },
    });
    expect(head.statusCode).toBe(200);
    const locked = head.json().data.items;
    expect(locked.length).toBeGreaterThanOrEqual(1);
  });

  it('deduplicates requests by uniqueKey', async () => {
    const create = await app.inject({
      method: 'POST',
      url: '/v2/request-queues',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'dedup-queue' },
    });
    const queueId = create.json().data.id;

    // Add same URL twice
    await app.inject({
      method: 'POST',
      url: `/v2/request-queues/${queueId}/requests`,
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://example.com', uniqueKey: 'same' },
    });
    const dup = await app.inject({
      method: 'POST',
      url: `/v2/request-queues/${queueId}/requests`,
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://example.com', uniqueKey: 'same' },
    });
    // Second add should return the existing request (wasAlreadyPresent)
    expect(dup.json().data.wasAlreadyPresent).toBe(true);
  });
});
```

**Step 2: Run the test**

Run: `npx vitest run --project integration packages/api/test/integration/request-queues.int.test.ts`

**Step 3: Commit**

```bash
git add packages/api/test/integration/request-queues.int.test.ts
git commit -m "test: add request queues integration test"
```

---

## Task 7: Write auth integration test

**Files:**

- Create: `packages/api/test/integration/auth.int.test.ts`

**Step 1: Write the test**

```typescript
import { describe, it, expect, beforeAll, afterEach, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import {
  createTestApp,
  runMigrations,
  createTestUser,
  cleanDatabase,
  ensureS3Bucket,
} from './setup.js';

describe('Auth (integration)', () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    await ensureS3Bucket();
    app = await createTestApp();
    await runMigrations();
  });

  afterEach(async () => {
    await cleanDatabase();
  });

  afterAll(async () => {
    await app.close();
  });

  it('logs in with valid credentials and gets a token', async () => {
    await createTestUser('login@test.local', 'mypassword');

    const login = await app.inject({
      method: 'POST',
      url: '/v2/auth/login',
      payload: { email: 'login@test.local', password: 'mypassword' },
    });
    expect(login.statusCode).toBe(200);
    expect(login.json().data.token).toBeDefined();
  });

  it('rejects invalid credentials', async () => {
    await createTestUser('real@test.local', 'correctpassword');

    const login = await app.inject({
      method: 'POST',
      url: '/v2/auth/login',
      payload: { email: 'real@test.local', password: 'wrongpassword' },
    });
    expect(login.statusCode).toBe(401);
  });

  it('rejects requests without auth token', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/v2/acts',
    });
    expect(res.statusCode).toBe(401);
  });

  it('creates and uses an API key', async () => {
    const user = await createTestUser('apikey@test.local', 'password123');

    // Create API key
    const keyRes = await app.inject({
      method: 'POST',
      url: '/v2/auth/api-keys',
      headers: { authorization: `Bearer ${user.token}` },
      payload: { name: 'test-key' },
    });
    expect(keyRes.statusCode).toBe(201);
    const apiKey = keyRes.json().data.key;
    expect(apiKey).toMatch(/^cp_/);

    // Use API key to list actors
    const actors = await app.inject({
      method: 'GET',
      url: '/v2/acts',
      headers: { authorization: `Bearer ${apiKey}` },
    });
    expect(actors.statusCode).toBe(200);
  });
});
```

**Step 2: Run the test**

Run: `npx vitest run --project integration packages/api/test/integration/auth.int.test.ts`

**Step 3: Commit**

```bash
git add packages/api/test/integration/auth.int.test.ts
git commit -m "test: add auth integration test"
```

---

## Task 8: Write actors + runs integration test

**Files:**

- Create: `packages/api/test/integration/actors.int.test.ts`

**Step 1: Write the test**

```typescript
import { describe, it, expect, beforeAll, afterEach, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import {
  createTestApp,
  runMigrations,
  createTestUser,
  cleanDatabase,
  ensureS3Bucket,
} from './setup.js';

describe('Actors & Runs (integration)', () => {
  let app: FastifyInstance;
  let token: string;

  beforeAll(async () => {
    await ensureS3Bucket();
    app = await createTestApp();
    await runMigrations();
    const user = await createTestUser();
    token = user.token;
  });

  afterEach(async () => {
    await cleanDatabase();
    const user = await createTestUser();
    token = user.token;
  });

  afterAll(async () => {
    await app.close();
  });

  it('creates an actor and starts a run', async () => {
    // Create actor
    const create = await app.inject({
      method: 'POST',
      url: '/v2/acts',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'my-scraper' },
    });
    expect(create.statusCode).toBe(201);
    const actorId = create.json().data.id;

    // Start run
    const run = await app.inject({
      method: 'POST',
      url: `/v2/acts/${actorId}/runs`,
      headers: { authorization: `Bearer ${token}` },
      payload: {},
    });
    expect(run.statusCode).toBe(201);
    const runId = run.json().data.id;
    expect(run.json().data.status).toBe('READY');

    // Get run
    const get = await app.inject({
      method: 'GET',
      url: `/v2/actor-runs/${runId}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(get.statusCode).toBe(200);
    expect(get.json().data.actorId).toBe(actorId);
  });

  it('lists only the current user actors (IDOR)', async () => {
    // User A creates actor
    await app.inject({
      method: 'POST',
      url: '/v2/acts',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'a-scraper' },
    });

    // User B
    const userB = await createTestUser('b@test.local', 'password123');
    const list = await app.inject({
      method: 'GET',
      url: '/v2/acts',
      headers: { authorization: `Bearer ${userB.token}` },
    });
    expect(list.json().data.items).toHaveLength(0);
  });
});
```

**Step 2: Run the test**

Run: `npx vitest run --project integration packages/api/test/integration/actors.int.test.ts`

**Step 3: Commit**

```bash
git add packages/api/test/integration/actors.int.test.ts
git commit -m "test: add actors and runs integration test"
```

---

## Task 9: Write docs drift check script

**Files:**

- Create: `scripts/check-docs-drift.ts`

**Step 1: Write the script**

```typescript
/**
 * Docs drift check — compares source-of-truth code definitions
 * against documentation markdown files.
 *
 * Usage: npx tsx scripts/check-docs-drift.ts <docs-dir>
 *   e.g.: npx tsx scripts/check-docs-drift.ts ../crawlee-cloud.github.io/src/docs
 *
 * Exit 0 = in sync, Exit 1 = drift found
 */

import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const docsDir = process.argv[2];

if (!docsDir) {
  console.error('Usage: npx tsx scripts/check-docs-drift.ts <docs-directory>');
  process.exit(1);
}

let driftFound = false;

function report(category: string, item: string) {
  console.error(`  DRIFT [${category}]: ${item} — present in code but not in docs`);
  driftFound = true;
}

// --- 1. Extract API routes from source ---
function extractRoutes(): string[] {
  const routesDir = join(ROOT, 'packages/api/src/routes');
  const routes: string[] = [];
  const routePattern = /\.(get|post|put|delete|patch)\s*[<(]\s*['"`]([^'"`]+)/g;

  for (const file of readdirSync(routesDir).filter((f) => f.endsWith('.ts'))) {
    const content = readFileSync(join(routesDir, file), 'utf8');
    let match: RegExpExecArray | null;
    while ((match = routePattern.exec(content)) !== null) {
      const method = match[1]!.toUpperCase();
      const path = match[2]!;
      routes.push(`${method} ${path}`);
    }
  }
  return routes;
}

// --- 2. Extract CLI commands from source ---
function extractCliCommands(): string[] {
  const commandsDir = join(ROOT, 'packages/cli/src/commands');
  try {
    return readdirSync(commandsDir)
      .filter((f) => f.endsWith('.ts'))
      .map((f) => f.replace('.ts', ''));
  } catch {
    return [];
  }
}

// --- 3. Extract env vars from config files ---
function extractEnvVars(): { api: string[]; runner: string[] } {
  const envPattern = /process\.env\.(\w+)/g;

  function extract(filePath: string): string[] {
    try {
      const content = readFileSync(filePath, 'utf8');
      const vars: string[] = [];
      let match: RegExpExecArray | null;
      while ((match = envPattern.exec(content)) !== null) {
        vars.push(match[1]!);
      }
      return [...new Set(vars)];
    } catch {
      return [];
    }
  }

  return {
    api: extract(join(ROOT, 'packages/api/src/config.ts')),
    runner: extract(join(ROOT, 'packages/runner/src/config.ts')),
  };
}

// --- 4. Check against docs ---
function readDoc(name: string): string {
  try {
    return readFileSync(join(resolve(docsDir), name), 'utf8');
  } catch {
    console.error(`  WARNING: docs file ${name} not found`);
    return '';
  }
}

// Check API routes
console.log('Checking API routes...');
const apiDoc = readDoc('api.md');
for (const route of extractRoutes()) {
  // Check that the path part appears somewhere in api.md
  const path = route.split(' ')[1]!;
  if (!apiDoc.includes(path)) {
    report('API route', route);
  }
}

// Check CLI commands
console.log('Checking CLI commands...');
const cliDoc = readDoc('cli.md');
for (const cmd of extractCliCommands()) {
  // Check command name appears in cli.md (as heading or backtick ref)
  if (!cliDoc.includes(cmd)) {
    report('CLI command', cmd);
  }
}

// Check env vars
console.log('Checking env vars...');
const deployDoc = readDoc('deployment.md');
const runnerDoc = readDoc('runner.md');

const envVars = extractEnvVars();
// Skip common/internal vars that don't need documentation
const skipVars = new Set(['NODE_ENV', 'npm_package_version']);

for (const v of envVars.api) {
  if (skipVars.has(v)) continue;
  if (!deployDoc.includes(v)) {
    report('API env var', `${v} (expected in deployment.md)`);
  }
}

for (const v of envVars.runner) {
  if (skipVars.has(v)) continue;
  if (!runnerDoc.includes(v) && !deployDoc.includes(v)) {
    report('Runner env var', `${v} (expected in runner.md or deployment.md)`);
  }
}

// --- Result ---
if (driftFound) {
  console.error('\nDocs drift detected! Please update documentation.');
  process.exit(1);
} else {
  console.log('\nAll checks passed — docs are in sync with code.');
  process.exit(0);
}
```

**Step 2: Run the script against the local docs repo**

Run: `npx tsx scripts/check-docs-drift.ts /Users/me/Workspace/personel/crawlee-cloud/crawlee-cloud.github.io/src/docs`

Expected: Exit 0 (docs were just updated to match code).

**Step 3: Commit**

```bash
git add scripts/check-docs-drift.ts
git commit -m "ci: add docs drift check script"
```

---

## Task 10: Create docs-check workflow

**Files:**

- Create: `.github/workflows/docs-check.yml`

**Step 1: Write the workflow**

```yaml
name: Docs Drift Check

on:
  push:
    branches: [main]
    paths:
      - 'packages/api/src/routes/**'
      - 'packages/api/src/config.ts'
      - 'packages/runner/src/config.ts'
      - 'packages/cli/src/commands/**'
  pull_request:
    paths:
      - 'packages/api/src/routes/**'
      - 'packages/api/src/config.ts'
      - 'packages/runner/src/config.ts'
      - 'packages/cli/src/commands/**'

jobs:
  check-docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/checkout@v4
        with:
          repository: crawlee-cloud/crawlee-cloud.github.io
          path: docs-repo

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - run: npm ci

      - name: Check docs drift
        run: npx tsx scripts/check-docs-drift.ts docs-repo/src/docs
```

**Step 2: Verify YAML syntax**

Run: `node -e "require('yaml').parse(require('fs').readFileSync('.github/workflows/docs-check.yml','utf8')); console.log('Valid')"`

**Step 3: Commit**

```bash
git add .github/workflows/docs-check.yml
git commit -m "ci: add docs drift check workflow"
```

---

## Task 11: Final verification

**Step 1: Run unit tests**

Run: `npx vitest run --project api --project runner --project cli`

Expected: All existing 86+ tests pass.

**Step 2: Run type check**

Run: `npx tsc --noEmit`

Expected: Exit 0.

**Step 3: Run lint**

Run: `npm run lint`

Expected: No errors.

**Step 4: Run docs drift check**

Run: `npx tsx scripts/check-docs-drift.ts /Users/me/Workspace/personel/crawlee-cloud/crawlee-cloud.github.io/src/docs`

Expected: Exit 0.

**Step 5: (Optional) Run integration tests locally**

If docker services are running (`npm run docker:dev`):

Run: `DATABASE_URL=postgresql://crawlee:devpassword@localhost:5432/crawlee_cloud S3_ACCESS_KEY=devminioadmin S3_SECRET_KEY=devminioadmin S3_BUCKET=crawlee-cloud API_SECRET=dev-secret-do-not-use-in-production-32chars CORS_ORIGINS=http://localhost:3000 npx vitest run --project integration`

Expected: All integration tests pass.

**Step 6: Commit any remaining fixes**

If any step above failed, fix the issue and commit before declaring done.
