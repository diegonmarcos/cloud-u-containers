/**
 * Cron scheduler — loads enabled schedules from DB,
 * registers node-cron jobs, and creates runs on tick.
 */

import cron from 'node-cron';
import { nanoid } from 'nanoid';
import { query } from './db/index.js';
import { redis } from './storage/redis.js';

interface ScheduleRow {
  id: string;
  user_id: string;
  actor_id: string;
  cron_expression: string;
  timezone: string;
  input: unknown;
}

const activeJobs = new Map<string, cron.ScheduledTask>();

/**
 * Initialize scheduler: load all enabled schedules and register cron jobs.
 */
export async function initScheduler(): Promise<void> {
  const result = await query<ScheduleRow>('SELECT * FROM schedules WHERE is_enabled = true');

  for (const schedule of result.rows) {
    registerSchedule(schedule);
  }

  console.log(`Scheduler initialized with ${result.rows.length} active schedules`);
}

/**
 * Register a single schedule as a cron job.
 */
export function registerSchedule(schedule: ScheduleRow): void {
  unregisterSchedule(schedule.id);

  if (!cron.validate(schedule.cron_expression)) {
    console.error(
      `Invalid cron expression for schedule ${schedule.id}: ${schedule.cron_expression}`
    );
    return;
  }

  const task = cron.schedule(
    schedule.cron_expression,
    () => {
      void triggerScheduledRun(schedule);
    },
    {
      timezone: schedule.timezone || 'UTC',
    }
  );

  activeJobs.set(schedule.id, task);
}

/**
 * Unregister (stop) a schedule's cron job.
 */
export function unregisterSchedule(scheduleId: string): void {
  const existing = activeJobs.get(scheduleId);
  if (existing) {
    void existing.stop();
    activeJobs.delete(scheduleId);
  }
}

/**
 * Create a new run when a schedule fires.
 */
async function triggerScheduledRun(schedule: ScheduleRow): Promise<void> {
  try {
    const runId = nanoid();
    const datasetId = nanoid();
    const kvStoreId = nanoid();
    const requestQueueId = nanoid();

    // Create default storages
    await query('INSERT INTO datasets (id, user_id) VALUES ($1, $2)', [
      datasetId,
      schedule.user_id,
    ]);
    await query('INSERT INTO key_value_stores (id, user_id) VALUES ($1, $2)', [
      kvStoreId,
      schedule.user_id,
    ]);
    await query('INSERT INTO request_queues (id, user_id) VALUES ($1, $2)', [
      requestQueueId,
      schedule.user_id,
    ]);

    // Store input in KV store
    const { putKVRecord } = await import('./storage/s3.js');
    await putKVRecord(kvStoreId, 'INPUT', JSON.stringify(schedule.input ?? {}), 'application/json');

    // Create run
    await query(
      `INSERT INTO runs (id, actor_id, user_id, status, default_dataset_id, default_key_value_store_id, default_request_queue_id)
       VALUES ($1, $2, $3, 'READY', $4, $5, $6)`,
      [runId, schedule.actor_id, schedule.user_id, datasetId, kvStoreId, requestQueueId]
    );

    // Update schedule timestamps
    await query('UPDATE schedules SET last_run_at = NOW(), modified_at = NOW() WHERE id = $1', [
      schedule.id,
    ]);

    // Notify runner
    await redis.publish('run:new', runId);

    console.log(`Schedule ${schedule.id} triggered run ${runId} for actor ${schedule.actor_id}`);
  } catch (err) {
    console.error(`Schedule ${schedule.id} failed to trigger run:`, err);
  }
}

/**
 * Reload a single schedule (called after CRUD operations).
 */
export async function reloadSchedule(scheduleId: string): Promise<void> {
  const result = await query<ScheduleRow>(
    'SELECT * FROM schedules WHERE id = $1 AND is_enabled = true',
    [scheduleId]
  );

  if (result.rows[0]) {
    registerSchedule(result.rows[0]);
  } else {
    unregisterSchedule(scheduleId);
  }
}

/**
 * Unregister (stop) all scheduled cron jobs.
 * Used during graceful shutdown.
 */
export function unregisterAllSchedules(): void {
  for (const [id, task] of activeJobs) {
    void task.stop();
    activeJobs.delete(id);
  }
}

/**
 * Get count of active cron jobs (for health checks).
 */
export function getActiveScheduleCount(): number {
  return activeJobs.size;
}
