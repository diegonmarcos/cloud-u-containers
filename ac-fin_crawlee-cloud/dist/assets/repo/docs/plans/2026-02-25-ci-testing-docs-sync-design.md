# CI Pipeline, Integration Tests & Docs Sync

## Problem

The platform is growing and needs automated guardrails:

- No CI pipeline exists (only CLI auto-publish)
- Tests are unit-only with mocked storage
- Docs drift from code silently

## Design

### 1. CI Pipeline (`ci.yml`)

Three parallel jobs triggered on push to main and all PRs:

**Job: lint-typecheck**

- `npm run lint`
- `npx tsc --noEmit`

**Job: unit-tests**

- `npx vitest run` (existing 86+ tests)

**Job: integration-tests**

- Service containers: PostgreSQL 16, Redis 7, MinIO
- Runs integration test suite against real services
- Separate vitest workspace project with 30s timeout

### 2. Integration Tests

Location: `packages/api/test/integration/`

**Setup** (`setup.ts`): Builds real Fastify instance connected to service containers. Each test file runs migrations, creates test user, cleans up after each test.

**Coverage:**

| Area               | What's tested                                          |
| ------------------ | ------------------------------------------------------ |
| CRUD lifecycle     | Create actor, start run, check status, get results     |
| Storage round-trip | pushData/getItems through S3 + PostgreSQL              |
| KV store           | setValue/getValue for binary + JSON via S3             |
| Request queues     | Add, lock, process, mark handled (PG locking)          |
| Auth               | Real JWT: register, login, use token, reject bad token |
| Pagination         | Offset/limit clamping against real queries             |
| IDOR               | User A cannot access User B's resources                |

**Vitest workspace** addition:

```typescript
{
  test: {
    name: 'integration',
    include: ['packages/api/test/integration/**/*.int.test.ts'],
    testTimeout: 30000,
  }
}
```

**Deferred:** Runner Docker execution, CLI e2e, Dashboard UI tests.

### 3. Docs Drift Check

**Script:** `scripts/check-docs-drift.ts`

Extracts from code and compares against docs:

| Check         | Source of truth                                       | Docs file                    |
| ------------- | ----------------------------------------------------- | ---------------------------- |
| API routes    | Route registrations in `packages/api/src/routes/*.ts` | `api.md`                     |
| CLI commands  | Command definitions in `packages/cli/src/commands/`   | `cli.md`                     |
| Env vars      | `process.env.*` in config files                       | `deployment.md`, `runner.md` |
| Runner config | Runner config file                                    | `runner.md`                  |

**Workflow** (`docs-check.yml`): Triggers on changes to routes, config, runner, or CLI commands. Clones docs repo, runs comparison script. Fails if code has items not documented.

Does not auto-update docs (prose context requires human judgment).

### 4. Existing Workflow

`publish-cli.yml` — unchanged, handles CLI auto-publish on version bump.

## Non-goals

- Docker-in-Docker for runner integration tests
- Auto-generating docs content
- Dashboard testing
- E2E CLI tests (deferred)
