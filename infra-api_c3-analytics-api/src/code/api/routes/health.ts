import type { FastifyInstance } from 'fastify';

export async function registerHealth(app: FastifyInstance) {
  app.get('/healthz', async () => ({ ok: true }));
}
