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
