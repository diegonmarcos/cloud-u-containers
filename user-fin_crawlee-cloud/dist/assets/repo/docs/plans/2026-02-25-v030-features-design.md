# v0.3.0 Features Design

**Date:** 2026-02-25

**Goal:** Implement the three remaining v0.3.0 roadmap features: cron scheduling, webhook improvements, and run retry policies. Three other roadmap items (run timeouts, resource limits, multi-worker) are already implemented.

## 1. Cron Scheduling

### Architecture

The scheduler runs as a module inside the API server process, using `node-cron` for cron expression parsing and scheduling. A new `schedules` table stores schedule definitions, each referencing an actor.

When a cron tick fires, the scheduler creates a new run with `READY` status (same flow as `POST /v2/acts/:actorId/runs`), which the runner picks up via the existing polling/notification mechanism.

### Schema — `schedules` table

| Column          | Type        | Description                       |
| --------------- | ----------- | --------------------------------- |
| id              | VARCHAR(21) | nanoid primary key                |
| user_id         | VARCHAR(21) | Owner (FK to users)               |
| actor_id        | VARCHAR(21) | Target actor (FK to actors)       |
| name            | TEXT        | Human-friendly name               |
| cron_expression | TEXT        | Standard 5-field cron expression  |
| timezone        | TEXT        | IANA timezone (default UTC)       |
| is_enabled      | BOOLEAN     | Active/paused toggle              |
| input           | JSONB       | Optional input passed to each run |
| last_run_at     | TIMESTAMPTZ | Last triggered time               |
| next_run_at     | TIMESTAMPTZ | Pre-computed next fire time       |
| created_at      | TIMESTAMPTZ | Creation timestamp                |
| modified_at     | TIMESTAMPTZ | Last modification timestamp       |

### API Endpoints

- `POST /v2/schedules` — Create schedule
- `GET /v2/schedules` — List user's schedules
- `GET /v2/schedules/:scheduleId` — Get schedule
- `PUT /v2/schedules/:scheduleId` — Update schedule
- `DELETE /v2/schedules/:scheduleId` — Delete schedule

### Startup Flow

On API server boot, load all enabled schedules from DB, register cron jobs in memory. The existing `scheduler.ts` stub will be replaced entirely.

---

## 2. Webhook Improvements

### Current State

Webhooks table exists with basic fields. Runner fires webhooks as fire-and-forget HTTP POSTs — no retries, no delivery tracking, no CRUD API.

### Schema Additions to `webhooks` table

| New Column  | Type        | Description                               |
| ----------- | ----------- | ----------------------------------------- |
| actor_id    | VARCHAR(21) | Optional: scope webhook to specific actor |
| headers     | JSONB       | Custom headers (e.g., auth tokens)        |
| description | TEXT        | User description                          |
| modified_at | TIMESTAMPTZ | Track updates                             |

### New `webhook_deliveries` table

| Column          | Type        | Description                     |
| --------------- | ----------- | ------------------------------- |
| id              | VARCHAR(21) | nanoid primary key              |
| webhook_id      | VARCHAR(21) | FK to webhooks                  |
| run_id          | VARCHAR(21) | Which run triggered this        |
| event_type      | TEXT        | e.g., ACTOR.RUN.SUCCEEDED       |
| status          | TEXT        | PENDING, DELIVERED, FAILED      |
| attempt_count   | INTEGER     | Current attempt (1-based)       |
| max_attempts    | INTEGER     | Default 5                       |
| next_retry_at   | TIMESTAMPTZ | When to retry                   |
| response_status | INTEGER     | HTTP status from target         |
| response_body   | TEXT        | First 1KB of response           |
| created_at      | TIMESTAMPTZ | When delivery was created       |
| finished_at     | TIMESTAMPTZ | When delivery completed/gave up |

### Retry Logic

Exponential backoff with delays: 10s, 30s, 60s, 300s, 900s (5 attempts total). A retry processor runs on a 10-second interval inside the runner, queries pending deliveries where `next_retry_at <= NOW()`, and retries.

### API Endpoints

- `POST /v2/webhooks` — Create webhook
- `GET /v2/webhooks` — List user's webhooks
- `GET /v2/webhooks/:webhookId` — Get webhook
- `PUT /v2/webhooks/:webhookId` — Update webhook
- `DELETE /v2/webhooks/:webhookId` — Delete webhook
- `GET /v2/webhooks/:webhookId/deliveries` — View delivery history

---

## 3. Run Retry Policies

### Schema Additions to `actors` table

| New Column       | Type    | Default | Description                        |
| ---------------- | ------- | ------- | ---------------------------------- |
| max_retries      | INTEGER | 0       | Max retry attempts for failed runs |
| retry_delay_secs | INTEGER | 60      | Delay between retries              |

### Schema Additions to `runs` table

| New Column    | Type        | Default | Description                          |
| ------------- | ----------- | ------- | ------------------------------------ |
| retry_count   | INTEGER     | 0       | Current retry attempt                |
| origin_run_id | VARCHAR(21) | NULL    | Original run that spawned this retry |
| run_after     | TIMESTAMPTZ | NULL    | Don't process before this time       |

### Retry Flow (in runner's processRun)

1. Run finishes with status `FAILED` (not `TIMED-OUT` or `ABORTED`)
2. Runner checks actor's `max_retries` — if `run.retry_count < actor.max_retries`:
   - Create new run with `retry_count = run.retry_count + 1`, `origin_run_id = original run id`
   - Set `run_after` to `NOW() + retry_delay_secs`
   - New run has `READY` status, picked up once `run_after` time passes
3. Runner poll query updated: `WHERE status = 'READY' AND (run_after IS NULL OR run_after <= NOW())`

### API Changes

Run response includes `retryCount` and `originRunId` fields. No new endpoints — retries are automatic.

---

## Implementation Order

1. **Database migrations** — All schema changes first (schedules table, webhook additions, webhook_deliveries table, actors/runs columns)
2. **Webhook improvements** — CRUD API + delivery tracking + retry processor (builds on existing code)
3. **Run retry policies** — Schema + runner logic (small, self-contained)
4. **Cron scheduling** — New schedules CRUD + scheduler module (most new code, benefits from webhook/retry being done)
