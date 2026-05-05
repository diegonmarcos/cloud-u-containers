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
