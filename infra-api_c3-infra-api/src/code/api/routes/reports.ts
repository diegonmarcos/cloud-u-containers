// ── Reports Routes — health-check report orchestration ──
// The report generators live in GitHub Actions, NOT in this API, on purpose:
// this API runs on oci-apps and may itself be down, so report *triggering* and
// report *data* must not depend on it being healthy.
//
// Two interchangeable runners, same `report` input, same published artifacts:
//   gha      -> cloud-health-reports-x86-gha.yml      (ubuntu-latest, default)
//   oci-apps -> cloud-health-reports-arm-oci-apps.yml (self-hosted arm64)
//
// Artifacts are published to the PUBLIC diegonmarcos/cloud-data repo, which
// serves them with `access-control-allow-origin: *`. Browsers therefore fetch
// report DATA directly from raw.githubusercontent and never through here — this
// module only orchestrates runs and reports their status.

import { FastifyPluginAsync } from "fastify";

const GH_API = "https://api.github.com";
const OWNER_REPO = "diegonmarcos/cloud-infra";
const RAW_BASE =
  "https://raw.githubusercontent.com/diegonmarcos/cloud-data/main/reports/dist";

// Runner -> workflow file. Keys are the only accepted `runner` values.
export const REPORT_RUNNERS: Record<string, string> = {
  gha: "cloud-health-reports-x86-gha.yml",
  "oci-apps": "cloud-health-reports-arm-oci-apps.yml",
};

// Mirrors the workflow_dispatch `report` input options. Anything else is rejected
// before it reaches GitHub.
export const REPORT_KINDS = [
  "all",
  "cloud",
  "mail",
  "url",
  "sec-network",
  "sec-data",
  "daily-mail",
] as const;

// Published artifact families (json + md per family).
export const REPORT_FAMILIES = [
  "cloud_health_daily",
  "cloud_mail_full",
  "cloud_sec_data",
  "cloud_sec_network",
] as const;

function ghHeaders(token?: string): Record<string, string> {
  const h: Record<string, string> = {
    accept: "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
    "user-agent": "c3-infra-api",
  };
  if (token) h.authorization = `Bearer ${token}`;
  return h;
}

export const registerReportsRoutes: FastifyPluginAsync = async (app) => {
  // ── List runners + report kinds (lets the UI build controls without hardcoding) ──
  app.get(
    "/reports/runners",
    {
      schema: {
        tags: ["reports"],
        summary: "Available report runners and report kinds",
      },
    },
    async () => ({
      runners: Object.keys(REPORT_RUNNERS),
      defaultRunner: "gha",
      kinds: REPORT_KINDS,
      families: REPORT_FAMILIES,
      // Told to the client so it can fetch data directly and stay working
      // even when this API is unreachable.
      dataBase: RAW_BASE,
      dispatchConfigured: Boolean(process.env.GITHUB_TOKEN),
    }),
  );

  // ── Freshness of each published family (HEAD only — no payload proxying) ──
  app.get(
    "/reports/status",
    { schema: { tags: ["reports"], summary: "Published report freshness" } },
    async () => {
      const out = await Promise.all(
        REPORT_FAMILIES.map(async (fam) => {
          const url = `${RAW_BASE}/${fam}.json`;
          try {
            const res = await fetch(url, {
              method: "HEAD",
              signal: AbortSignal.timeout(8000),
            });
            const lm = res.headers.get("last-modified");
            const ageH = lm
              ? Math.round((Date.now() - new Date(lm).getTime()) / 36e5)
              : null;
            return {
              family: fam,
              ok: res.ok,
              status: res.status,
              lastModified: lm,
              ageHours: ageH,
              stale: ageH === null ? null : ageH > 48,
              json: url,
              markdown: `${RAW_BASE}/${fam}.md`,
            };
          } catch (e) {
            return {
              family: fam,
              ok: false,
              error: e instanceof Error ? e.message : String(e),
              json: url,
              markdown: `${RAW_BASE}/${fam}.md`,
            };
          }
        }),
      );
      return { families: out, base: RAW_BASE };
    },
  );

  // ── Recent runs for both workflows ──
  app.get(
    "/reports/runs",
    { schema: { tags: ["reports"], summary: "Recent report workflow runs" } },
    async (_req, reply) => {
      const token = process.env.GITHUB_TOKEN;
      const runs: unknown[] = [];
      for (const [runner, wf] of Object.entries(REPORT_RUNNERS)) {
        try {
          const res = await fetch(
            `${GH_API}/repos/${OWNER_REPO}/actions/workflows/${wf}/runs?per_page=10`,
            { headers: ghHeaders(token), signal: AbortSignal.timeout(10000) },
          );
          if (!res.ok) continue;
          const body = (await res.json()) as any;
          for (const r of body.workflow_runs ?? []) {
            runs.push({
              runner,
              id: r.id,
              status: r.status,
              conclusion: r.conclusion,
              createdAt: r.created_at,
              updatedAt: r.updated_at,
              event: r.event,
              url: r.html_url,
            });
          }
        } catch {
          // A single workflow being unreachable must not fail the whole listing.
        }
      }
      runs.sort((a: any, b: any) => (a.createdAt < b.createdAt ? 1 : -1));
      return reply.send({ runs });
    },
  );

  // ── Single run status (for polling after a dispatch) ──
  app.get<{ Params: { id: string } }>(
    "/reports/runs/:id",
    {
      schema: {
        tags: ["reports"],
        summary: "Status of one report run",
        params: {
          type: "object",
          required: ["id"],
          properties: { id: { type: "string", pattern: "^[0-9]+$" } },
        },
      },
    },
    async (req, reply) => {
      const res = await fetch(
        `${GH_API}/repos/${OWNER_REPO}/actions/runs/${req.params.id}`,
        {
          headers: ghHeaders(process.env.GITHUB_TOKEN),
          signal: AbortSignal.timeout(10000),
        },
      );
      if (!res.ok)
        return reply.code(res.status).send({ error: `github: ${res.status}` });
      const r = (await res.json()) as any;
      return reply.send({
        id: r.id,
        status: r.status,
        conclusion: r.conclusion,
        createdAt: r.created_at,
        updatedAt: r.updated_at,
        url: r.html_url,
      });
    },
  );

  // ── Trigger a report run ──
  app.post<{ Body: { report?: string; runner?: string } }>(
    "/reports/run",
    {
      schema: {
        tags: ["reports"],
        summary: "Dispatch a report workflow (default runner: gha)",
        body: {
          type: "object",
          properties: {
            report: { type: "string", enum: REPORT_KINDS as unknown as string[] },
            runner: {
              type: "string",
              enum: Object.keys(REPORT_RUNNERS),
              default: "gha",
            },
          },
        },
      },
    },
    async (req, reply) => {
      const report = req.body?.report ?? "all";
      const runner = req.body?.runner ?? "gha";

      // Validate against allowlists before anything leaves this process.
      if (!REPORT_KINDS.includes(report as (typeof REPORT_KINDS)[number]))
        return reply.code(400).send({ error: `unknown report: ${report}` });
      const workflow = REPORT_RUNNERS[runner];
      if (!workflow)
        return reply.code(400).send({ error: `unknown runner: ${runner}` });

      const token = process.env.GITHUB_TOKEN;
      if (!token)
        return reply.code(501).send({
          error: "GITHUB_TOKEN not configured on c3-infra-api",
          hint:
            "Add GITHUB_TOKEN (scope: actions:write) to this app's sops secrets.yaml, " +
            "or dispatch from the browser with a user-supplied PAT.",
        });

      const res = await fetch(
        `${GH_API}/repos/${OWNER_REPO}/actions/workflows/${workflow}/dispatches`,
        {
          method: "POST",
          headers: { ...ghHeaders(token), "content-type": "application/json" },
          body: JSON.stringify({ ref: "main", inputs: { report } }),
          signal: AbortSignal.timeout(15000),
        },
      );

      // 204 No Content is the documented success for workflow dispatches.
      if (res.status !== 204) {
        const detail = await res.text().catch(() => "");
        return reply
          .code(502)
          .send({ error: `dispatch failed: ${res.status}`, detail: detail.slice(0, 400) });
      }

      return reply.send({ ok: true, report, runner, workflow });
    },
  );
};
