import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

const RESEND_BASE = "https://api.resend.com";
const DEFAULT_FROM = "Diego <no-reply@mails.diegonmarcos.com>";

function getApiKey(): string {
  const key = process.env.RESEND_API_KEY;
  if (!key) throw new Error("RESEND_API_KEY not set");
  return key;
}

async function resendFetch(path: string, opts: RequestInit = {}): Promise<any> {
  const resp = await fetch(`${RESEND_BASE}${path}`, {
    ...opts,
    headers: {
      Authorization: `Bearer ${getApiKey()}`,
      "Content-Type": "application/json",
      ...opts.headers,
    },
  });
  const body = await resp.text();
  if (!resp.ok) throw new Error(`Resend API ${resp.status}: ${body}`);
  return body ? JSON.parse(body) : {};
}

export function registerResendTools(server: McpServer): void {
  // ── resend_send ─────────────────────────────────────────────
  server.tool(
    "resend_send",
    "Send email via Resend API (uses mails.diegonmarcos.com domain)",
    {
      to: z.string().describe("Recipient(s), comma-separated"),
      subject: z.string().describe("Email subject"),
      body: z.string().describe("Plain text body"),
      from: z.string().optional().describe(`From address (default: ${DEFAULT_FROM})`),
      html: z.string().optional().describe("HTML body (optional)"),
      cc: z.string().optional().describe("CC address(es)"),
      bcc: z.string().optional().describe("BCC address(es)"),
      reply_to: z.string().optional().describe("Reply-To address"),
    },
    async ({ to, subject, body, from, html, cc, bcc, reply_to }) => {
      const payload: Record<string, any> = {
        from: from ?? DEFAULT_FROM,
        to: to.split(",").map((s) => s.trim()),
        subject,
        text: body,
      };
      if (html) payload.html = html;
      if (cc) payload.cc = cc.split(",").map((s) => s.trim());
      if (bcc) payload.bcc = bcc.split(",").map((s) => s.trim());
      if (reply_to) payload.reply_to = reply_to;

      const result = await resendFetch("/emails", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      return { content: [{ type: "text", text: `Sent via Resend. ID: ${result.id}` }] };
    }
  );

  // ── resend_get ──────────────────────────────────────────────
  server.tool(
    "resend_get",
    "Get email status/details by Resend email ID",
    {
      email_id: z.string().describe("Resend email ID"),
    },
    async ({ email_id }) => {
      const result = await resendFetch(`/emails/${email_id}`);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2),
          },
        ],
      };
    }
  );

  // ── resend_list ─────────────────────────────────────────────
  server.tool(
    "resend_list",
    "List recent emails sent via Resend",
    {},
    async () => {
      const result = await resendFetch("/emails");
      const emails = result.data ?? [];
      if (emails.length === 0) {
        return { content: [{ type: "text", text: "No emails found" }] };
      }
      const lines = emails.map((e: any) =>
        `${e.id}  ${e.created_at?.slice(0, 19) ?? "?"}  ${e.last_event ?? "?"}  → ${(e.to ?? []).join(", ")}  "${e.subject ?? ""}"`
      );
      return { content: [{ type: "text", text: `${emails.length} emails:\n${lines.join("\n")}` }] };
    }
  );

  // ── resend_domains ──────────────────────────────────────────
  server.tool(
    "resend_domains",
    "List verified sending domains in Resend",
    {},
    async () => {
      const result = await resendFetch("/domains");
      const domains = result.data ?? [];
      if (domains.length === 0) {
        return { content: [{ type: "text", text: "No domains configured" }] };
      }
      const lines = domains.map((d: any) =>
        `${d.name}  status=${d.status}  region=${d.region ?? "?"}  created=${d.created_at?.slice(0, 10) ?? "?"}`
      );
      return { content: [{ type: "text", text: `${domains.length} domains:\n${lines.join("\n")}` }] };
    }
  );

  // ── resend_domain_verify ────────────────────────────────────
  server.tool(
    "resend_domain_verify",
    "Trigger domain verification in Resend (checks DNS records)",
    {
      domain_id: z.string().describe("Domain ID from resend_domains"),
    },
    async ({ domain_id }) => {
      const result = await resendFetch(`/domains/${domain_id}/verify`, {
        method: "POST",
      });
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    }
  );

  // ── resend_domain_dns ───────────────────────────────────────
  server.tool(
    "resend_domain_dns",
    "Get required DNS records for a Resend domain",
    {
      domain_id: z.string().describe("Domain ID from resend_domains"),
    },
    async ({ domain_id }) => {
      const result = await resendFetch(`/domains/${domain_id}`);
      const records = result.records ?? [];
      if (records.length === 0) {
        return { content: [{ type: "text", text: "No DNS records found" }] };
      }
      const lines = records.map((r: any) =>
        `${r.record_type ?? r.type}  ${r.name}  ${r.value?.slice(0, 60) ?? "?"}  status=${r.status ?? "?"}`
      );
      return {
        content: [
          {
            type: "text",
            text: `Domain: ${result.name}\nStatus: ${result.status}\n\nDNS records:\n${lines.join("\n")}`,
          },
        ],
      };
    }
  );

  // ── resend_api_keys ─────────────────────────────────────────
  server.tool(
    "resend_api_keys",
    "List Resend API keys (names only, not secrets)",
    {},
    async () => {
      const result = await resendFetch("/api-keys");
      const keys = result.data ?? [];
      if (keys.length === 0) {
        return { content: [{ type: "text", text: "No API keys" }] };
      }
      const lines = keys.map((k: any) =>
        `${k.id}  ${k.name}  created=${k.created_at?.slice(0, 10) ?? "?"}`
      );
      return { content: [{ type: "text", text: `${keys.length} API keys:\n${lines.join("\n")}` }] };
    }
  );
}
