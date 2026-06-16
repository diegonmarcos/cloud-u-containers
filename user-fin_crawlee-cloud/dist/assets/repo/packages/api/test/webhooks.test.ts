/**
 * Webhook Routes Tests
 */

import { describe, it, expect, beforeAll, afterAll, beforeEach, vi } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { ZodError } from 'zod';

// Mock authenticate middleware BEFORE importing routes
vi.mock('../src/auth/middleware.js', () => ({
  authenticate: async (request: { user?: { id: string; email: string; role: string } }) => {
    request.user = { id: 'test-user-id', email: 'test@example.com', role: 'user' };
  },
}));

import { webhooksRoutes } from '../src/routes/webhooks.js';

const mockQuery = vi.fn();
vi.mock('../src/db/index.js', () => ({
  query: (...args: unknown[]) => mockQuery(...args) as unknown,
  pool: { query: vi.fn() },
}));

vi.mock('../src/storage/redis.js', () => ({
  redis: {
    get: vi.fn(),
    set: vi.fn(),
    publish: vi.fn(),
  },
}));

const createWebhookRow = (overrides = {}) => ({
  id: 'webhook-1',
  user_id: 'test-user-id',
  event_types: ['ACTOR.RUN.SUCCEEDED'],
  request_url: 'https://example.com/hook',
  payload_template: null,
  actor_id: null,
  headers: null,
  description: 'Test webhook',
  is_enabled: true,
  created_at: new Date(),
  modified_at: new Date(),
  ...overrides,
});

const createDeliveryRow = (overrides = {}) => ({
  id: 'delivery-1',
  webhook_id: 'webhook-1',
  run_id: 'run-1',
  event_type: 'ACTOR.RUN.SUCCEEDED',
  status: 'DELIVERED',
  attempt_count: 1,
  max_attempts: 3,
  next_retry_at: null,
  response_status: 200,
  response_body: '{"ok":true}',
  created_at: new Date(),
  finished_at: new Date(),
  ...overrides,
});

describe('Webhook Routes', () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    app = Fastify();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    app.setErrorHandler((error: any, _request, reply) => {
      if (error instanceof ZodError) {
        return reply.status(400).send({
          error: {
            type: 'validation_error',
            message: 'Validation failed',
            details: error.errors,
          },
        });
      }
      reply.status(500).send({ error: { message: error.message } });
    });
    app.register(webhooksRoutes, { prefix: '/v2' });
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
  });

  beforeEach(() => {
    mockQuery.mockReset();
  });

  describe('POST /v2/webhooks', () => {
    it('should create a webhook', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [createWebhookRow()] });

      const response = await app.inject({
        method: 'POST',
        url: '/v2/webhooks',
        payload: {
          eventTypes: ['ACTOR.RUN.SUCCEEDED'],
          requestUrl: 'https://example.com/hook',
          description: 'Test webhook',
        },
      });

      expect(response.statusCode).toBe(201);
      const body = JSON.parse(response.body);
      expect(body.data.id).toBe('webhook-1');
      expect(body.data.eventTypes).toEqual(['ACTOR.RUN.SUCCEEDED']);
      expect(body.data.requestUrl).toBe('https://example.com/hook');
      expect(body.data.isEnabled).toBe(true);
    });

    it('should reject invalid request body', async () => {
      const response = await app.inject({
        method: 'POST',
        url: '/v2/webhooks',
        payload: {
          eventTypes: [],
          requestUrl: 'not-a-url',
        },
      });

      expect(response.statusCode).toBe(400);
    });
  });

  describe('GET /v2/webhooks', () => {
    it('should list user webhooks', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [
          createWebhookRow(),
          createWebhookRow({ id: 'webhook-2', description: 'Second webhook' }),
        ],
      });

      const response = await app.inject({
        method: 'GET',
        url: '/v2/webhooks',
      });

      expect(response.statusCode).toBe(200);
      const body = JSON.parse(response.body);
      expect(body.data.items).toHaveLength(2);
      expect(body.data.total).toBe(2);
      expect(body.data.offset).toBe(0);
      expect(body.data.limit).toBe(100);
    });

    it('should return empty list when no webhooks exist', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [] });

      const response = await app.inject({
        method: 'GET',
        url: '/v2/webhooks',
      });

      expect(response.statusCode).toBe(200);
      const body = JSON.parse(response.body);
      expect(body.data.items).toHaveLength(0);
      expect(body.data.total).toBe(0);
    });
  });

  describe('GET /v2/webhooks/:webhookId', () => {
    it('should get webhook by id', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [createWebhookRow()] });

      const response = await app.inject({
        method: 'GET',
        url: '/v2/webhooks/webhook-1',
      });

      expect(response.statusCode).toBe(200);
      const body = JSON.parse(response.body);
      expect(body.data.id).toBe('webhook-1');
    });

    it('should return 404 for non-existent webhook', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [] });

      const response = await app.inject({
        method: 'GET',
        url: '/v2/webhooks/non-existent',
      });

      expect(response.statusCode).toBe(404);
      const body = JSON.parse(response.body);
      expect(body.error.message).toBe('Webhook not found');
    });
  });

  describe('PUT /v2/webhooks/:webhookId', () => {
    it('should update webhook', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [createWebhookRow({ description: 'Updated description' })],
      });

      const response = await app.inject({
        method: 'PUT',
        url: '/v2/webhooks/webhook-1',
        payload: { description: 'Updated description' },
      });

      expect(response.statusCode).toBe(200);
      const body = JSON.parse(response.body);
      expect(body.data.description).toBe('Updated description');
    });

    it('should return 404 for non-existent webhook', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [] });

      const response = await app.inject({
        method: 'PUT',
        url: '/v2/webhooks/non-existent',
        payload: { description: 'Updated' },
      });

      expect(response.statusCode).toBe(404);
    });
  });

  describe('DELETE /v2/webhooks/:webhookId', () => {
    it('should delete webhook', async () => {
      mockQuery.mockResolvedValueOnce({ rowCount: 1, rows: [{ id: 'webhook-1' }] });

      const response = await app.inject({
        method: 'DELETE',
        url: '/v2/webhooks/webhook-1',
      });

      expect(response.statusCode).toBe(204);
    });

    it('should return 404 for missing webhook', async () => {
      mockQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });

      const response = await app.inject({
        method: 'DELETE',
        url: '/v2/webhooks/non-existent',
      });

      expect(response.statusCode).toBe(404);
      const body = JSON.parse(response.body);
      expect(body.error.message).toBe('Webhook not found');
    });
  });

  describe('GET /v2/webhooks/:webhookId/deliveries', () => {
    it('should list webhook deliveries', async () => {
      mockQuery
        .mockResolvedValueOnce({ rows: [createWebhookRow()] }) // ownership check
        .mockResolvedValueOnce({ rows: [createDeliveryRow()] }) // deliveries
        .mockResolvedValueOnce({ rows: [{ count: '1' }] }); // count

      const response = await app.inject({
        method: 'GET',
        url: '/v2/webhooks/webhook-1/deliveries',
      });

      expect(response.statusCode).toBe(200);
      const body = JSON.parse(response.body);
      expect(body.data.items).toHaveLength(1);
      expect(body.data.items[0].id).toBe('delivery-1');
      expect(body.data.items[0].status).toBe('DELIVERED');
      expect(body.data.total).toBe(1);
    });

    it('should return 404 when webhook not found', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [] }); // ownership check fails

      const response = await app.inject({
        method: 'GET',
        url: '/v2/webhooks/non-existent/deliveries',
      });

      expect(response.statusCode).toBe(404);
    });

    it('should support pagination parameters', async () => {
      mockQuery
        .mockResolvedValueOnce({ rows: [createWebhookRow()] })
        .mockResolvedValueOnce({ rows: [] })
        .mockResolvedValueOnce({ rows: [{ count: '0' }] });

      const response = await app.inject({
        method: 'GET',
        url: '/v2/webhooks/webhook-1/deliveries?offset=10&limit=5',
      });

      expect(response.statusCode).toBe(200);
      const body = JSON.parse(response.body);
      expect(body.data.offset).toBe(10);
      expect(body.data.limit).toBe(5);
    });
  });
});
