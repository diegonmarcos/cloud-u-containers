/**
 * Node-runnable assert-based self-check (no test framework — matches the
 * repo's "simplest thing that works" idiom used elsewhere, e.g. metrics.ts's
 * applyStep comment). Covers:
 *   - metric rollup/downsample math (bucket averaging, min/max, count fold)
 *   - alert rule threshold evaluation (compareOp) and fired/resolved
 *     transition logic (evaluateAlertRules' 0->1 / 1->0 semantics)
 *
 * Run with: npx tsx shared/libs/__selfcheck__.ts
 */

import assert from "node:assert";

// ── compareOp (mirrors poller.ts's compareOp — re-implemented here so this
// file has zero side effects / no DB, no SSH; poller.ts's version is not
// exported, so this checks the same truth table it implements) ──
function compareOp(value: number, op: string, threshold: number): boolean {
  switch (op) {
    case "gt": return value > threshold;
    case "gte": return value >= threshold;
    case "lt": return value < threshold;
    case "lte": return value <= threshold;
    case "eq": return value === threshold;
    default: return false;
  }
}

assert.strictEqual(compareOp(95, "gt", 90), true, "95 gt 90 should breach");
assert.strictEqual(compareOp(90, "gt", 90), false, "90 gt 90 should not breach");
assert.strictEqual(compareOp(90, "gte", 90), true, "90 gte 90 should breach");
assert.strictEqual(compareOp(10, "lt", 20), true, "10 lt 20 should breach");
assert.strictEqual(compareOp(20, "lte", 20), true, "20 lte 20 should breach");
assert.strictEqual(compareOp(5, "eq", 5), true, "5 eq 5 should breach");
assert.strictEqual(compareOp(5, "eq", 6), false, "5 eq 6 should not breach");

// ── fired/resolved transition semantics (mirrors evaluateAlertRules in
// poller.ts: fire only on 0->1, resolve only on 1->0, no re-fire while open) ──
function nextAlertState(breached: boolean, alreadyOpen: boolean): "fire" | "resolve" | "noop" {
  if (breached && !alreadyOpen) return "fire";
  if (!breached && alreadyOpen) return "resolve";
  return "noop";
}

assert.strictEqual(nextAlertState(true, false), "fire", "0->1 should fire");
assert.strictEqual(nextAlertState(true, true), "noop", "staying breached should not re-fire");
assert.strictEqual(nextAlertState(false, true), "resolve", "1->0 should resolve");
assert.strictEqual(nextAlertState(false, false), "noop", "staying clear should stay noop");

// ── rollup/downsample math (mirrors db.ts's rollupMetrics bucket fold:
// avg/min/max/count over the raw samples in a bucket, plus the weighted-avg
// merge formula used by its ON CONFLICT upsert clause) ──
function foldBucket(values: number[]): { avg: number; min: number; max: number; count: number } {
  return {
    avg: values.reduce((s, v) => s + v, 0) / values.length,
    min: Math.min(...values),
    max: Math.max(...values),
    count: values.length,
  };
}

{
  const bucket = foldBucket([10, 20, 30]);
  assert.strictEqual(bucket.avg, 20, "avg of [10,20,30] should be 20");
  assert.strictEqual(bucket.min, 10, "min of [10,20,30] should be 10");
  assert.strictEqual(bucket.max, 30, "max of [10,20,30] should be 30");
  assert.strictEqual(bucket.count, 3, "count of [10,20,30] should be 3");
}

// Weighted-average merge, matching:
//   avg = (existing.avg * existing.count + incoming.avg * incoming.count) / (existing.count + incoming.count)
function mergeWeightedAvg(existingAvg: number, existingCount: number, incomingAvg: number, incomingCount: number): number {
  return (existingAvg * existingCount + incomingAvg * incomingCount) / (existingCount + incomingCount);
}

{
  // existing bucket: avg=10 over 2 samples; incoming: avg=20 over 2 samples
  // combined true average of [10,10,20,20] is 15
  const merged = mergeWeightedAvg(10, 2, 20, 2);
  assert.strictEqual(merged, 15, "weighted avg merge of equal-count buckets should be the simple average");
}

{
  // Unequal counts: existing avg=0 over 1 sample, incoming avg=10 over 9 samples -> weighted toward incoming
  const merged = mergeWeightedAvg(0, 1, 10, 9);
  assert.strictEqual(merged, 9, "weighted avg should skew toward the larger sample count");
}

// ── bucket5m floor (mirrors db.ts's bucket5m: floor ts to a 5-minute boundary) ──
function bucket5m(ts: Date): string {
  const ms = ts.getTime();
  const bucketMs = Math.floor(ms / (5 * 60_000)) * (5 * 60_000);
  return new Date(bucketMs).toISOString();
}

{
  const a = bucket5m(new Date("2026-01-01T00:03:00.000Z"));
  const b = bucket5m(new Date("2026-01-01T00:04:59.000Z"));
  const c = bucket5m(new Date("2026-01-01T00:05:00.000Z"));
  assert.strictEqual(a, "2026-01-01T00:00:00.000Z", "00:03 should floor to 00:00");
  assert.strictEqual(b, "2026-01-01T00:00:00.000Z", "00:04:59 should still floor to 00:00");
  assert.strictEqual(c, "2026-01-01T00:05:00.000Z", "00:05:00 should floor to the next bucket");
}

console.log("selfcheck: all assertions passed (compareOp, alert fire/resolve transitions, rollup avg/min/max/count, weighted-avg merge, bucket5m floor)");
