/**
 * Actor routes - Apify-compatible endpoints for managing Actors.
 */

import type { FastifyPluginAsync } from 'fastify';
import { nanoid } from 'nanoid';
import { CreateActorSchema, UpdateActorSchema, ActorRunSchema } from '../schemas/actors.js';
import { query } from '../db/index.js';
import { redis } from '../storage/redis.js';
import { authenticate } from '../auth/middleware.js';

interface ActorRow {
  id: string;
  name: string;
  user_id: string | null;
  title: string | null;
  description: string | null;
  default_run_options: Record<string, unknown> | null;
  max_retries: number;
  retry_delay_secs: number;
  created_at: Date;
  modified_at: Date;
}

export const actorsRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.addHook('preHandler', authenticate);

  /**
   * GET /v2/acts - List actors (filtered by user)
   */
  fastify.get('/acts', async (request) => {
    const result = await query<ActorRow>(
      'SELECT * FROM actors WHERE user_id = $1 ORDER BY created_at DESC LIMIT 100',
      [request.user!.id]
    );

    return {
      data: {
        total: result.rows.length,
        count: result.rows.length,
        offset: 0,
        limit: 100,
        items: result.rows.map(formatActor),
      },
    };
  });

  /**
   * POST /v2/acts - Create or update actor (upsert by name)
   */
  fastify.post<{
    Body: {
      name: string;
      title?: string;
      description?: string;
      defaultRunOptions?: Record<string, unknown>;
      maxRetries?: number;
      retryDelaySecs?: number;
    };
  }>('/acts', async (request, reply) => {
    const { name, title, description, defaultRunOptions, maxRetries, retryDelaySecs } =
      CreateActorSchema.parse(request.body);

    // Check if actor with this name already exists for this user
    const existing = await query<ActorRow>(
      'SELECT * FROM actors WHERE name = $1 AND user_id = $2',
      [name, request.user!.id]
    );

    if (existing.rows[0]) {
      // Update existing actor (user_id already verified in SELECT)
      const result = await query<ActorRow>(
        `
        UPDATE actors
        SET title = $1, description = $2, default_run_options = $3,
            max_retries = $4, retry_delay_secs = $5, modified_at = NOW()
        WHERE name = $6 AND user_id = $7
        RETURNING *
      `,
        [
          title ?? existing.rows[0].title,
          description ?? existing.rows[0].description,
          defaultRunOptions
            ? JSON.stringify(defaultRunOptions)
            : existing.rows[0].default_run_options,
          maxRetries ?? existing.rows[0].max_retries,
          retryDelaySecs ?? existing.rows[0].retry_delay_secs,
          name,
          request.user!.id,
        ]
      );

      return { data: formatActor(result.rows[0]!) };
    }

    // Create new actor with user ownership
    const id = nanoid();
    const result = await query<ActorRow>(
      `
      INSERT INTO actors (id, name, user_id, title, description, default_run_options, max_retries, retry_delay_secs)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      RETURNING *
    `,
      [
        id,
        name,
        request.user!.id,
        title ?? null,
        description ?? null,
        defaultRunOptions ? JSON.stringify(defaultRunOptions) : null,
        maxRetries ?? 0,
        retryDelaySecs ?? 60,
      ]
    );

    reply.status(201);
    return { data: formatActor(result.rows[0]!) };
  });

  /**
   * GET /v2/acts/:actorId - Get actor (user-scoped)
   */
  fastify.get<{ Params: { actorId: string } }>('/acts/:actorId', async (request, reply) => {
    const { actorId } = request.params;

    // Get actor by ID or name, scoped to user
    const result = await query<ActorRow>(
      `SELECT * FROM actors WHERE (id = $1 OR name = $1) AND user_id = $2`,
      [actorId, request.user!.id]
    );

    if (!result.rows[0]) {
      reply.status(404);
      return { error: { message: 'Actor not found' } };
    }

    return { data: formatActor(result.rows[0]) };
  });

  /**
   * PUT /v2/acts/:actorId - Update actor
   */
  fastify.put<{
    Params: { actorId: string };
    Body: {
      name?: string;
      title?: string;
      description?: string;
    };
  }>('/acts/:actorId', async (request, reply) => {
    const { actorId } = request.params;
    const updates = UpdateActorSchema.parse(request.body);

    const setClauses: string[] = ['modified_at = NOW()'];
    const values: unknown[] = [];
    let paramIndex = 1;

    if (updates.name !== undefined) {
      setClauses.push(`name = $${paramIndex++}`);
      values.push(updates.name);
    }
    if (updates.title !== undefined) {
      setClauses.push(`title = $${paramIndex++}`);
      values.push(updates.title);
    }
    if (updates.description !== undefined) {
      setClauses.push(`description = $${paramIndex++}`);
      values.push(updates.description);
    }

    values.push(actorId);
    const actorIdParam = paramIndex++;
    values.push(request.user!.id);
    const userIdParam = paramIndex++;

    const result = await query<ActorRow>(
      `
      UPDATE actors SET ${setClauses.join(', ')}
      WHERE (id = $${actorIdParam} OR name = $${actorIdParam}) AND user_id = $${userIdParam}
      RETURNING *
    `,
      values
    );

    if (!result.rows[0]) {
      reply.status(404);
      return { error: { message: 'Actor not found' } };
    }

    return { data: formatActor(result.rows[0]) };
  });

  /**
   * DELETE /v2/acts/:actorId - Delete actor (user-scoped)
   */
  fastify.delete<{ Params: { actorId: string } }>('/acts/:actorId', async (request, reply) => {
    const { actorId } = request.params;
    const result = await query(
      `DELETE FROM actors WHERE (id = $1 OR name = $1) AND user_id = $2 RETURNING id`,
      [actorId, request.user!.id]
    );
    if (result.rowCount === 0) {
      reply.status(404);
      return { error: { message: 'Actor not found' } };
    }
    reply.status(204);
  });

  /**
   * POST /v2/acts/:actorId/runs - Start actor run
   */
  fastify.post<{
    Params: { actorId: string };
    Body: {
      input?: unknown;
      timeout?: number;
      memory?: number;
      envVars?: Record<string, string>;
    };
  }>('/acts/:actorId/runs', async (request, reply) => {
    const { actorId } = request.params;
    const {
      input,
      timeout = 3600,
      memory = 1024,
      envVars,
    } = ActorRunSchema.parse(request.body || {});

    // Get actor by ID or name, scoped to user
    const actor = await query<ActorRow>(
      `SELECT * FROM actors WHERE (id = $1 OR name = $1) AND user_id = $2`,
      [actorId, request.user!.id]
    );

    if (!actor.rows[0]) {
      reply.status(404);
      return { error: { message: 'Actor not found' } };
    }

    // Create default storages for this run
    const datasetId = nanoid();
    const kvStoreId = nanoid();
    const requestQueueId = nanoid();
    const runId = nanoid();

    // Create storages with user ownership
    await query('INSERT INTO datasets (id, user_id) VALUES ($1, $2)', [
      datasetId,
      request.user!.id,
    ]);
    await query('INSERT INTO key_value_stores (id, user_id) VALUES ($1, $2)', [
      kvStoreId,
      request.user!.id,
    ]);
    await query('INSERT INTO request_queues (id, user_id) VALUES ($1, $2)', [
      requestQueueId,
      request.user!.id,
    ]);

    // Always store input in the KV store (empty object if not provided)
    const { putKVRecord } = await import('../storage/s3.js');
    await putKVRecord(kvStoreId, 'INPUT', JSON.stringify(input ?? {}), 'application/json');

    // Create run record with READY status so Runner picks it up (with user ownership)
    const result = await query<{
      id: string;
      actor_id: string;
      status: string;
      started_at: Date;
      default_dataset_id: string;
      default_key_value_store_id: string;
      default_request_queue_id: string;
      timeout_secs: number;
      memory_mbytes: number;
      created_at: Date;
    }>(
      `
      INSERT INTO runs (id, actor_id, user_id, status, default_dataset_id, default_key_value_store_id, default_request_queue_id, timeout_secs, memory_mbytes)
      VALUES ($1, $2, $3, 'READY', $4, $5, $6, $7, $8)
      RETURNING *
    `,
      [
        runId,
        actor.rows[0].id,
        request.user!.id,
        datasetId,
        kvStoreId,
        requestQueueId,
        timeout,
        memory,
      ]
    );

    // Store runtime env vars in Redis if provided
    if (envVars && Object.keys(envVars).length > 0) {
      await redis.set(`run:${runId}:envVars`, JSON.stringify(envVars), 'EX', 86400);
    }

    // Notify Runner about new job
    await redis.publish('run:new', runId);

    reply.status(201);
    return {
      data: {
        id: result.rows[0]!.id,
        actId: actor.rows[0].id,
        status: result.rows[0]!.status,
        startedAt: result.rows[0]!.started_at,
        defaultDatasetId: datasetId,
        defaultKeyValueStoreId: kvStoreId,
        defaultRequestQueueId: requestQueueId,
      },
    };
  });

  /**
   * POST /v2/acts/:actorId/run-sync - Run actor and wait for finish
   * (Simplified version - in production would need actual container execution)
   */
  fastify.post<{
    Params: { actorId: string };
    Body: { input?: unknown };
  }>('/acts/:actorId/run-sync', async (request, _reply) => {
    // For now, just create the run - actual execution would be handled by runner service
    return (fastify as any).inject({
      method: 'POST',
      url: `/v2/acts/${request.params.actorId}/runs`,
      payload: request.body,
    });
  });
};

function formatActor(row: ActorRow) {
  return {
    id: row.id,
    name: row.name,
    userId: row.user_id,
    title: row.title,
    description: row.description,
    defaultRunOptions: row.default_run_options,
    maxRetries: row.max_retries,
    retryDelaySecs: row.retry_delay_secs,
    createdAt: row.created_at,
    modifiedAt: row.modified_at,
  };
}
