/**
 * Webhook routes - CRUD endpoints for managing webhooks and viewing delivery history.
 */

import type { FastifyPluginAsync } from 'fastify';
import { nanoid } from 'nanoid';
import { CreateWebhookSchema, UpdateWebhookSchema } from '../schemas/webhooks.js';
import { query } from '../db/index.js';
import { authenticate } from '../auth/middleware.js';

interface WebhookRow {
  id: string;
  user_id: string;
  event_types: string[];
  request_url: string;
  payload_template: string | null;
  actor_id: string | null;
  headers: Record<string, string> | null;
  description: string | null;
  is_enabled: boolean;
  created_at: Date;
  modified_at: Date;
}

interface DeliveryRow {
  id: string;
  webhook_id: string;
  run_id: string | null;
  event_type: string;
  status: string;
  attempt_count: number;
  max_attempts: number;
  next_retry_at: Date | null;
  response_status: number | null;
  response_body: string | null;
  created_at: Date;
  finished_at: Date | null;
}

export const webhooksRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.addHook('preHandler', authenticate);

  /**
   * POST /v2/webhooks - Create webhook
   */
  fastify.post<{
    Body: {
      eventTypes: string[];
      requestUrl: string;
      payloadTemplate?: string;
      actorId?: string;
      headers?: Record<string, string>;
      description?: string;
      isEnabled?: boolean;
    };
  }>('/webhooks', async (request, reply) => {
    const data = CreateWebhookSchema.parse(request.body);

    const id = nanoid();
    const result = await query<WebhookRow>(
      `INSERT INTO webhooks (id, user_id, event_types, request_url, payload_template, actor_id, headers, description, is_enabled)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       RETURNING *`,
      [
        id,
        request.user!.id,
        data.eventTypes,
        data.requestUrl,
        data.payloadTemplate ?? null,
        data.actorId ?? null,
        data.headers ? JSON.stringify(data.headers) : null,
        data.description ?? null,
        data.isEnabled ?? true,
      ]
    );

    reply.status(201);
    return { data: formatWebhook(result.rows[0]!) };
  });

  /**
   * GET /v2/webhooks - List user's webhooks
   */
  fastify.get('/webhooks', async (request) => {
    const result = await query<WebhookRow>(
      'SELECT * FROM webhooks WHERE user_id = $1 ORDER BY created_at DESC LIMIT 100',
      [request.user!.id]
    );

    return {
      data: {
        total: result.rows.length,
        count: result.rows.length,
        offset: 0,
        limit: 100,
        items: result.rows.map(formatWebhook),
      },
    };
  });

  /**
   * GET /v2/webhooks/:webhookId - Get single webhook (user-scoped)
   */
  fastify.get<{ Params: { webhookId: string } }>('/webhooks/:webhookId', async (request, reply) => {
    const { webhookId } = request.params;

    const result = await query<WebhookRow>(
      'SELECT * FROM webhooks WHERE id = $1 AND user_id = $2',
      [webhookId, request.user!.id]
    );

    if (!result.rows[0]) {
      reply.status(404);
      return { error: { message: 'Webhook not found' } };
    }

    return { data: formatWebhook(result.rows[0]) };
  });

  /**
   * PUT /v2/webhooks/:webhookId - Update webhook (user-scoped)
   */
  fastify.put<{
    Params: { webhookId: string };
    Body: {
      eventTypes?: string[];
      requestUrl?: string;
      payloadTemplate?: string;
      actorId?: string;
      headers?: Record<string, string>;
      description?: string;
      isEnabled?: boolean;
    };
  }>('/webhooks/:webhookId', async (request, reply) => {
    const { webhookId } = request.params;
    const updates = UpdateWebhookSchema.parse(request.body);

    const setClauses: string[] = ['modified_at = NOW()'];
    const values: unknown[] = [];
    let paramIndex = 1;

    if (updates.eventTypes !== undefined) {
      setClauses.push(`event_types = $${paramIndex++}`);
      values.push(updates.eventTypes);
    }
    if (updates.requestUrl !== undefined) {
      setClauses.push(`request_url = $${paramIndex++}`);
      values.push(updates.requestUrl);
    }
    if (updates.payloadTemplate !== undefined) {
      setClauses.push(`payload_template = $${paramIndex++}`);
      values.push(updates.payloadTemplate);
    }
    if (updates.actorId !== undefined) {
      setClauses.push(`actor_id = $${paramIndex++}`);
      values.push(updates.actorId);
    }
    if (updates.headers !== undefined) {
      setClauses.push(`headers = $${paramIndex++}`);
      values.push(JSON.stringify(updates.headers));
    }
    if (updates.description !== undefined) {
      setClauses.push(`description = $${paramIndex++}`);
      values.push(updates.description);
    }
    if (updates.isEnabled !== undefined) {
      setClauses.push(`is_enabled = $${paramIndex++}`);
      values.push(updates.isEnabled);
    }

    values.push(webhookId);

    // Add user_id filter for authorization
    values.push(request.user!.id);
    const result = await query<WebhookRow>(
      `UPDATE webhooks SET ${setClauses.join(', ')}
       WHERE id = $${paramIndex} AND user_id = $${paramIndex + 1}
       RETURNING *`,
      values
    );

    if (!result.rows[0]) {
      reply.status(404);
      return { error: { message: 'Webhook not found' } };
    }

    return { data: formatWebhook(result.rows[0]) };
  });

  /**
   * DELETE /v2/webhooks/:webhookId - Delete webhook (user-scoped)
   */
  fastify.delete<{ Params: { webhookId: string } }>(
    '/webhooks/:webhookId',
    async (request, reply) => {
      const { webhookId } = request.params;
      const result = await query(
        'DELETE FROM webhooks WHERE id = $1 AND user_id = $2 RETURNING id',
        [webhookId, request.user!.id]
      );

      if (result.rowCount === 0) {
        reply.status(404);
        return { error: { message: 'Webhook not found' } };
      }

      reply.status(204);
    }
  );

  /**
   * GET /v2/webhooks/:webhookId/deliveries - List delivery history (user-scoped, paginated)
   */
  fastify.get<{
    Params: { webhookId: string };
    Querystring: { offset?: string; limit?: string };
  }>('/webhooks/:webhookId/deliveries', async (request, reply) => {
    const { webhookId } = request.params;
    const offset = Math.max(0, parseInt(request.query.offset || '0', 10) || 0);
    const limit = Math.min(1000, Math.max(1, parseInt(request.query.limit || '100', 10) || 100));

    // Verify webhook ownership
    const webhook = await query<WebhookRow>(
      'SELECT * FROM webhooks WHERE id = $1 AND user_id = $2',
      [webhookId, request.user!.id]
    );

    if (!webhook.rows[0]) {
      reply.status(404);
      return { error: { message: 'Webhook not found' } };
    }

    const result = await query<DeliveryRow>(
      'SELECT * FROM webhook_deliveries WHERE webhook_id = $1 ORDER BY created_at DESC LIMIT $2 OFFSET $3',
      [webhookId, limit, offset]
    );

    const countResult = await query<{ count: string }>(
      'SELECT COUNT(*)::text AS count FROM webhook_deliveries WHERE webhook_id = $1',
      [webhookId]
    );

    const total = parseInt(countResult.rows[0]?.count ?? '0', 10);

    return {
      data: {
        total,
        count: result.rows.length,
        offset,
        limit,
        items: result.rows.map(formatDelivery),
      },
    };
  });
};

function formatWebhook(row: WebhookRow) {
  return {
    id: row.id,
    userId: row.user_id,
    eventTypes: row.event_types,
    requestUrl: row.request_url,
    payloadTemplate: row.payload_template,
    actorId: row.actor_id,
    headers: row.headers,
    description: row.description,
    isEnabled: row.is_enabled,
    createdAt: row.created_at,
    modifiedAt: row.modified_at,
  };
}

function formatDelivery(row: DeliveryRow) {
  return {
    id: row.id,
    webhookId: row.webhook_id,
    runId: row.run_id,
    eventType: row.event_type,
    status: row.status,
    attemptCount: row.attempt_count,
    maxAttempts: row.max_attempts,
    nextRetryAt: row.next_retry_at,
    responseStatus: row.response_status,
    responseBody: row.response_body,
    createdAt: row.created_at,
    finishedAt: row.finished_at,
  };
}
