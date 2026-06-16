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
