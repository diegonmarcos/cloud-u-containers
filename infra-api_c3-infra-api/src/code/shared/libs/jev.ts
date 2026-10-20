/**
 * Jev advisory client (#882 S3): ask the jev-sidecar (WireGuard mesh, `jev-gate serve`) how urgent an
 * alert is. Jev only RE-RANKS: the caller's hard-coded priority is the fallback and is used on ANY
 * failure -- no sidecar, no key (OPENROUTER_API_KEY unset), timeout, HTTP error, malformed answer,
 * observe-only / gate closed, not confident, a priority the caller did not offer. Never throws, never
 * waits longer than JEV_TIMEOUT_MS, and never ranks below "default" (an alert is never silenced by Jev).
 * Zero imports so a test can load it without the runtime.
 */

export type JevPriority = "default" | "high" | "urgent";
const OPTIONS: JevPriority[] = ["default", "high", "urgent"];

export interface JevAlertState {
  rule: string;
  target: string;
  metric: string;
  op: string;
  threshold: number;
  value: number;
}

export async function jevAlertPriority(
  state: JevAlertState,
  fetchImpl: typeof fetch = fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<JevPriority | null> {
  try {
    if (env.JEV_ALERTS === "0") return null;
    const base = env.JEV_SIDECAR_URL ?? "http://10.0.0.6:3110";
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), Number(env.JEV_TIMEOUT_MS ?? 2500));
    try {
      const res = await fetchImpl(`${base}/decide/alert_priority`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        signal: ctl.signal,
        body: JSON.stringify({
          state,
          questions: {
            priority: {
              type: "choice",
              instructions:
                "How urgently should a human be interrupted for this fleet alert (rule, target, metric, value against its threshold)?",
              criteria: {
                default: "Worth knowing, but can wait for the next time the person looks at their phone.",
                high: "Needs attention soon; the normal alert level.",
                urgent: "Needs attention immediately: something is failing or about to.",
              },
            },
          },
        }),
      });
      if (!res.ok) return null;
      const ans: any = await res.json();
      const r = ans?.ok === true ? ans.results?.priority : null;
      if (!r || r.confident !== true || !OPTIONS.includes(r.pick)) return null;
      return r.pick as JevPriority;
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return null;
  }
}
