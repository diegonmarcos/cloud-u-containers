/**
 * Metrics Endpoint Tests
 */

import { describe, it, expect, beforeAll, afterAll, vi } from 'vitest';
import Fastify from 'fastify';
import type { FastifyInstance } from 'fastify';

// Mock all external dependencies that index.ts imports
vi.mock('../src/auth/middleware.js', () => ({
  authenticate: async (request: { user?: { id: string; email: string; role: string } }) => {
    request.user = { id: 'test-user-id', email: 'test@example.com', role: 'user' };
  },
}));

vi.mock('../src/db/index.js', () => ({
  pool: { query: vi.fn().mockResolvedValue({ rows: [] }) },
  query: vi.fn().mockResolvedValue({ rows: [] }),
  initDatabase: vi.fn(),
}));

vi.mock('../src/storage/redis.js', () => ({
  redis: { ping: vi.fn(), publish: vi.fn(), on: vi.fn() },
  initRedis: vi.fn(),
}));

vi.mock('../src/storage/s3.js', () => ({
  s3: { send: vi.fn() },
  initS3: vi.fn(),
}));

vi.mock('../src/config.js', () => ({
  config: {
    port: 3000,
    logLevel: 'error',
    corsOrigins: 'http://localhost:3000',
    s3Bucket: 'test-bucket',
  },
}));

vi.mock('../src/config-validator.js', () => ({
  enforceSecurityConfig: vi.fn(),
}));

vi.mock('../src/setup.js', () => ({
  setupAdminUser: vi.fn(),
}));

vi.mock('../src/scheduler.js', () => ({
  initScheduler: vi.fn(),
  getActiveScheduleCount: () => 0,
  registerSchedule: vi.fn(),
  unregisterSchedule: vi.fn(),
  reloadSchedule: vi.fn(),
  unregisterAllSchedules: vi.fn(),
}));

// Import metrics to access the registry
import { registry } from '../src/metrics.js';

describe('Metrics Endpoint', () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    // Create a simple Fastify app with just the metrics endpoint
    app = Fastify();
    app.get('/metrics', async (_request, reply) => {
      reply.header('Content-Type', registry.contentType);
      return registry.metrics();
    });
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
  });

  it('should return Prometheus text format', async () => {
    const response = await app.inject({ method: 'GET', url: '/metrics' });
    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toContain('text/plain');
    // Should contain default Node.js metrics
    expect(response.body).toContain('process_cpu');
    // Should contain our custom metrics
    expect(response.body).toContain('http_requests_total');
    expect(response.body).toContain('http_request_duration_seconds');
    expect(response.body).toContain('actor_runs_total');
    expect(response.body).toContain('actor_runs_active');
    expect(response.body).toContain('webhook_deliveries_total');
    expect(response.body).toContain('scheduler_active_jobs');
    expect(response.body).toContain('db_pool_active_connections');
    expect(response.body).toContain('db_pool_idle_connections');
  });
});
