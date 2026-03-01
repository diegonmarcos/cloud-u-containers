# Type Fixes Required

## Database Functions (db.ts)

Actual signatures:
- `getHealthHistory(query: { vm?: string; since?: string; limit?: number } = {})`
- `getUptime Report(vm?: string, hours = 24)`
- `getAuditLog(query: { tool?: string; since?: string; limit?: number } = {})`
- `getDeployHistory(query: { service?: string; limit?: number } = {})`
- `getAlertState(vm: string)` → returns `{ lastStatus, lastChange, notified } | null`
- `updateAlertState(vm: string, status: string, notified: boolean)`
- `pruneOldRecords(daysToKeep = 30)` → returns `{ healthDeleted, auditDeleted, deployDeleted }`

## Notification Functions (notify.ts)

Actual signatures:
- `alertHealthDown(vm: string, details: string)`
- `alertHealthRecovered(vm: string)` - only 1 param!
- `alertDiskFull(vm: string, percent: string)` - percent is string, not number!

## Security Functions (security.ts)

Actual signatures:
- `securityTokens()` - takes NO parameters!

## Docker Functions (docker.ts)

Actual signatures:
- `logsMulti(serviceName: string, lines = 50)` - NOT (vm, containers[])!
- Returns `{ ok, output }` not array

## Fixes Needed

1. mcp/tools/database.ts - fix all query object calls
2. mcp/tools/notify.ts - fix alertHealthRecovered (1 param), alertDiskFull (percent: string)
3. mcp/tools/security.ts - fix securityTokens() to take no params
4. mcp/tools/docker.ts - fix logsMulti signature, containerPause/Unpause return types
5. api/routes/database.ts - fix all query object calls
6. api/routes/notify.ts - fix alertHealthRecovered, alertDiskFull
7. api/routes/security.ts - fix securityTokens
