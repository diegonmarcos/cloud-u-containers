import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec as execCb } from "child_process";
import { promisify } from "util";
import { withImap } from "../shared/imap.js";

const execAsync = promisify(execCb);

const STALWART_API = process.env.STALWART_ADMIN_URL || "https://mail.diegonmarcos.com";
const STALWART_USER = process.env.STALWART_ADMIN_USER || "admin";
const STALWART_PASS = process.env.STALWART_ADMIN_PASSWORD || "";
const DOMAIN = "diegonmarcos.com";
const CF_ACCOUNT_ID = "e5cb0a0c6f448e54f217de484259f0ae";

// ── Helpers ──────────────────────────────────────────────────────────

async function sshExec(alias: string, cmd: string, timeoutMs = 15000): Promise<string> {
  try {
    const { stdout } = await execAsync(
      `ssh -o ConnectTimeout=10 -o BatchMode=yes -o ControlPath=none ${alias} '${cmd.replace(/'/g, "'\\''")}'`,
      { timeout: timeoutMs },
    );
    return stdout.trim();
  } catch (e: any) {
    return `SSH_FAIL: ${e.message?.split("\n")[0] ?? e}`;
  }
}

async function digExec(query: string): Promise<string> {
  try {
    const { stdout } = await execAsync(`dig +short ${query}`, { timeout: 10000 });
    return stdout.trim() || "(empty)";
  } catch (e: any) {
    return `DIG_FAIL: ${e.message?.split("\n")[0] ?? e}`;
  }
}

async function stalwartQueue(): Promise<string> {
  try {
    const headers: Record<string, string> = {
      Authorization: `Basic ${Buffer.from(`${STALWART_USER}:${STALWART_PASS}`).toString("base64")}`,
      "Content-Type": "application/json",
    };
    const resp = await fetch(`${STALWART_API}/api/queue/messages`, { headers });
    if (!resp.ok) return `API_ERROR: ${resp.status} ${await resp.text()}`;
    const data = await resp.json();
    const items = Array.isArray(data) ? data : (data as any).items ?? data;
    if (Array.isArray(items) && items.length === 0) return "Queue empty";
    return JSON.stringify(items, null, 2);
  } catch (e: any) {
    return `QUEUE_FAIL: ${e.message?.split("\n")[0] ?? e}`;
  }
}

function status(ok: boolean): string {
  return ok ? "[PASS]" : "[FAIL]";
}

function isFail(output: string): boolean {
  return /^(SSH_FAIL|DIG_FAIL|API_ERROR|QUEUE_FAIL|TIMEOUT)/.test(output);
}

// ── Registration ─────────────────────────────────────────────────────

export function registerDebugTools(server: McpServer): void {
  // ══════════════════════════════════════════════════════════════════
  // Tool 1: debug_outbound
  // ══════════════════════════════════════════════════════════════════
  server.tool(
    "debug_outbound",
    "Debug outbound mail relay -- traces the full send path with logs",
    {
      minutes: z.number().default(5).describe("How many minutes of logs to check (default 5)"),
    },
    async ({ minutes }) => {
      const sections: string[] = [];
      const m = Math.max(1, Math.min(60, minutes));

      // Run independent checks in parallel
      const [
        queueResult,
        sshBatchResult,
        dnsResults,
      ] = await Promise.all([
        // 1. Stalwart queue
        stalwartQueue(),

        // 2+3+4+5. SSH batch: stalwart logs, smtp-proxy logs, OCI relay, AWS relay
        sshExec("oci-mail", [
          `echo "===STALWART_LOGS==="`,
          `docker logs stalwart --since ${m}m 2>&1 | grep -iE "queue|relay|delivery|bounce|reject|error|fail|next-hop|remote|connect" | tail -30`,
          `echo "===SMTP_PROXY_LOGS==="`,
          `docker logs smtp-proxy --since ${m}m 2>&1 | tail -20`,
          `echo "===OCI_RELAY==="`,
          `echo QUIT | timeout 5 openssl s_client -starttls smtp -connect smtp.email.eu-marseille-1.oci.oraclecloud.com:587 -quiet 2>&1 | head -3`,
          `echo "===AWS_RELAY==="`,
          `echo QUIT | timeout 5 openssl s_client -starttls smtp -connect email-smtp.us-east-1.amazonaws.com:587 -quiet 2>&1 | head -3`,
        ].join(" ; "), 30000),

        // 6. DNS checks (parallel)
        Promise.all([
          digExec(`MX ${DOMAIN}`),
          digExec(`TXT ${DOMAIN}`),
          digExec(`TXT dkim._domainkey.${DOMAIN}`),
          digExec(`TXT _dmarc.${DOMAIN}`),
        ]),
      ]);

      // Parse SSH batch output
      const sshSections: Record<string, string> = {};
      if (!isFail(sshBatchResult)) {
        const parts = sshBatchResult.split(/===(\w+)===/);
        for (let i = 1; i < parts.length; i += 2) {
          sshSections[parts[i]] = (parts[i + 1] ?? "").trim();
        }
      }

      // -- Section 1: Stalwart Queue
      const queueOk = !isFail(queueResult) && !queueResult.includes("API_ERROR");
      const queueEmpty = queueResult === "Queue empty";
      sections.push([
        `== 1. Stalwart Queue ${status(queueOk)} ==`,
        queueEmpty ? "  Queue is empty (no stuck messages)" : queueResult,
      ].join("\n"));

      // -- Section 2: Stalwart Logs
      const stalwartLogs = isFail(sshBatchResult) ? sshBatchResult : (sshSections["STALWART_LOGS"] || "(no matching log lines)");
      const logsHaveErrors = /error|fail|reject|bounce/i.test(stalwartLogs) && stalwartLogs !== "(no matching log lines)";
      sections.push([
        `== 2. Stalwart Outbound Logs (${m}m) ${status(!logsHaveErrors && !isFail(sshBatchResult))} ==`,
        stalwartLogs || "(no matching log lines)",
      ].join("\n"));

      // -- Section 3: SMTP-Proxy Logs
      const proxyLogs = isFail(sshBatchResult) ? sshBatchResult : (sshSections["SMTP_PROXY_LOGS"] || "(no log lines)");
      sections.push([
        `== 3. SMTP-Proxy Logs (${m}m) ${status(!isFail(sshBatchResult))} ==`,
        proxyLogs || "(no log lines)",
      ].join("\n"));

      // -- Section 4: OCI Relay Connect
      const ociRelay = isFail(sshBatchResult) ? sshBatchResult : (sshSections["OCI_RELAY"] || "(no output)");
      const ociOk = /250|220|SMTP/.test(ociRelay);
      sections.push([
        `== 4. OCI Relay (smtp.email.eu-marseille-1.oci.oraclecloud.com:587) ${status(ociOk)} ==`,
        ociRelay,
      ].join("\n"));

      // -- Section 5: AWS Relay Connect
      const awsRelay = isFail(sshBatchResult) ? sshBatchResult : (sshSections["AWS_RELAY"] || "(no output)");
      const awsOk = /250|220|SMTP/.test(awsRelay);
      sections.push([
        `== 5. AWS Relay (email-smtp.us-east-1.amazonaws.com:587) ${status(awsOk)} ==`,
        awsRelay,
      ].join("\n"));

      // -- Section 6: DNS Auth Records
      const [mxResult, spfResult, dkimResult, dmarcResult] = dnsResults;
      const mxOk = !!mxResult && mxResult !== "(empty)" && !isFail(mxResult);
      const spfOk = /v=spf1/.test(spfResult);
      const dkimOk = !!dkimResult && dkimResult !== "(empty)" && !isFail(dkimResult);
      const dmarcOk = /v=DMARC1/.test(dmarcResult);
      sections.push([
        `== 6. DNS Auth Records ==`,
        `  MX    ${status(mxOk)}  ${mxResult}`,
        `  SPF   ${status(spfOk)}  ${spfResult.split("\n").join(" | ")}`,
        `  DKIM  ${status(dkimOk)}  ${dkimResult.length > 120 ? dkimResult.slice(0, 120) + "..." : dkimResult}`,
        `  DMARC ${status(dmarcOk)}  ${dmarcResult}`,
      ].join("\n"));

      // Summary
      const allOk = queueOk && !logsHaveErrors && ociOk && mxOk && spfOk && dkimOk && dmarcOk;
      const header = allOk
        ? "=== OUTBOUND DEBUG: ALL CHECKS PASSED ==="
        : "=== OUTBOUND DEBUG: ISSUES DETECTED ===";

      return {
        content: [{
          type: "text",
          text: `${header}\n\n${sections.join("\n\n")}`,
        }],
      };
    },
  );

  // ══════════════════════════════════════════════════════════════════
  // Tool 2: debug_inbound
  // ══════════════════════════════════════════════════════════════════
  server.tool(
    "debug_inbound",
    "Debug inbound mail delivery -- traces the full receive path with logs",
    {
      minutes: z.number().default(10).describe("How many minutes of logs to check (default 10)"),
    },
    async ({ minutes }) => {
      const sections: string[] = [];
      const m = Math.max(1, Math.min(60, minutes));

      // Run independent checks in parallel
      const [
        dnsResults,
        cfWorkerResult,
        gcpSshResult,
        ociSshResult,
        queueResult,
        imapResult,
      ] = await Promise.all([
        // 1. MX DNS
        digExec(`MX ${DOMAIN}`),

        // 2. Cloudflare Workers check
        (async (): Promise<string> => {
          const cfKey = process.env.CF_API_KEY;
          const cfEmail = process.env.CF_API_EMAIL;
          if (!cfKey || !cfEmail) return "SKIPPED: CF_API_KEY / CF_API_EMAIL not set";
          try {
            const resp = await fetch(
              `https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/email-forwarder`,
              { headers: { "X-Auth-Key": cfKey, "X-Auth-Email": cfEmail } },
            );
            if (resp.status === 404) return "Worker 'email-forwarder' not found (404)";
            if (!resp.ok) return `CF API ${resp.status}: ${await resp.text()}`;
            const data = await resp.json() as any;
            return data.success ? "Worker 'email-forwarder' exists and is deployed" : `CF response: ${JSON.stringify(data.errors)}`;
          } catch (e: any) {
            return `CF_FAIL: ${e.message?.split("\n")[0] ?? e}`;
          }
        })(),

        // 3. Caddy L4 logs on gcp-proxy
        sshExec("gcp-proxy", `docker logs caddy --since ${m}m 2>&1 | grep -iE ":25|layer4|smtp|l4" | tail -10`, 15000),

        // 4+5+8. SSH batch to oci-mail: SMTP banner, inbound logs, account check
        sshExec("oci-mail", [
          `echo "===SMTP_BANNER==="`,
          `echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`,
          `echo "===INBOUND_LOGS==="`,
          `docker logs stalwart --since ${m}m 2>&1 | grep -iE "ingest|received|accept|reject|spam|junk|from=|to=|message|deliver|rcpt|envelope" | tail -20`,
          `echo "===ACCOUNT_CHECK==="`,
          `docker exec stalwart cat /opt/stalwart-mail/etc/config.toml 2>/dev/null | grep -i "me@diegonmarcos" || echo "account not found in config"`,
        ].join(" ; "), 20000),

        // 6. Stalwart queue
        stalwartQueue(),

        // 7. IMAP inbox count
        (async (): Promise<string> => {
          try {
            const count = await withImap(async (client) => {
              const lock = await client.getMailboxLock("INBOX");
              try {
                return client.mailbox?.exists ?? 0;
              } finally {
                lock.release();
              }
            });
            return `INBOX contains ${count} message(s)`;
          } catch (e: any) {
            return `IMAP_FAIL: ${e.message?.split("\n")[0] ?? e}`;
          }
        })(),
      ]);

      // Parse oci-mail SSH batch
      const ociSections: Record<string, string> = {};
      if (!isFail(ociSshResult)) {
        const parts = ociSshResult.split(/===(\w+)===/);
        for (let i = 1; i < parts.length; i += 2) {
          ociSections[parts[i]] = (parts[i + 1] ?? "").trim();
        }
      }

      // -- Section 1: MX DNS
      const mxOk = !!dnsResults && dnsResults !== "(empty)" && !isFail(dnsResults);
      sections.push([
        `== 1. MX DNS Record ${status(mxOk)} ==`,
        `  dig MX ${DOMAIN}: ${dnsResults}`,
      ].join("\n"));

      // -- Section 2: Cloudflare Workers
      const cfOk = cfWorkerResult.includes("exists") || cfWorkerResult.startsWith("SKIPPED");
      sections.push([
        `== 2. Cloudflare Email Worker ${status(cfOk)} ==`,
        `  ${cfWorkerResult}`,
      ].join("\n"));

      // -- Section 3: Caddy L4 passthrough
      const caddyLogs = gcpSshResult || "(no matching log lines)";
      const caddyOk = !isFail(gcpSshResult);
      sections.push([
        `== 3. Caddy L4 SMTP Passthrough (gcp-proxy, ${m}m) ${status(caddyOk)} ==`,
        caddyLogs,
      ].join("\n"));

      // -- Section 4: SMTP Banner
      const smtpBanner = isFail(ociSshResult) ? ociSshResult : (ociSections["SMTP_BANNER"] || "(no output)");
      const smtpOk = /220/.test(smtpBanner);
      sections.push([
        `== 4. Stalwart SMTP :25 Banner ${status(smtpOk)} ==`,
        `  ${smtpBanner}`,
      ].join("\n"));

      // -- Section 5: Inbound Logs
      const inboundLogs = isFail(ociSshResult) ? ociSshResult : (ociSections["INBOUND_LOGS"] || "(no matching log lines)");
      const inboundErrors = /reject|spam|junk|error|fail/i.test(inboundLogs) && inboundLogs !== "(no matching log lines)";
      sections.push([
        `== 5. Stalwart Inbound Logs (${m}m) ${status(!inboundErrors && !isFail(ociSshResult))} ==`,
        inboundLogs || "(no matching log lines)",
      ].join("\n"));

      // -- Section 6: Queue
      const queueOk = !isFail(queueResult) && !queueResult.includes("API_ERROR");
      const queueEmpty = queueResult === "Queue empty";
      sections.push([
        `== 6. Stalwart Queue ${status(queueOk)} ==`,
        queueEmpty ? "  Queue is empty" : queueResult,
      ].join("\n"));

      // -- Section 7: IMAP Store
      const imapOk = imapResult.startsWith("INBOX");
      sections.push([
        `== 7. IMAP Store ${status(imapOk)} ==`,
        `  ${imapResult}`,
      ].join("\n"));

      // -- Section 8: Account Check
      const accountOut = isFail(ociSshResult) ? ociSshResult : (ociSections["ACCOUNT_CHECK"] || "(no output)");
      const accountOk = /me@diegonmarcos/.test(accountOut) && !/not found/.test(accountOut);
      sections.push([
        `== 8. Stalwart Account (me@diegonmarcos.com) ${status(accountOk)} ==`,
        `  ${accountOut}`,
      ].join("\n"));

      // Summary
      const allOk = mxOk && smtpOk && !inboundErrors && queueOk && imapOk && accountOk;
      const header = allOk
        ? "=== INBOUND DEBUG: ALL CHECKS PASSED ==="
        : "=== INBOUND DEBUG: ISSUES DETECTED ===";

      return {
        content: [{
          type: "text",
          text: `${header}\n\n${sections.join("\n\n")}`,
        }],
      };
    },
  );
}
