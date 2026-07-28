import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec as execCb } from "child_process";
import { promisify } from "util";
import { withImap } from "../shared/imap.js";
import { DOMAIN, getServer, serverSchema, type ServerConfig } from "../shared/config.js";

const execAsync = promisify(execCb);

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

async function serverQueue(srv: ServerConfig, serverName: string): Promise<string> {
  if (serverName === "maddy") {
    return sshExec(srv.sshAlias, `docker exec ${srv.container} maddy queue list 2>&1 || echo 'Queue empty'`, 15000);
  }
  return sshExec(srv.sshAlias, `docker logs ${srv.container} --since 5m 2>&1 | grep -iE 'queue|pending|retry|delivery' | tail -10 || echo 'No queue activity'`, 15000);
}

function status(ok: boolean): string {
  return ok ? "[PASS]" : "[FAIL]";
}

function isFail(output: string): boolean {
  return /^(SSH_FAIL|DIG_FAIL|API_ERROR|QUEUE_FAIL|TIMEOUT)/.test(output);
}

// ── Handlers ─────────────────────────────────────────────────────────

export async function handle_debug_outbound({ server: srvName, minutes }: { server: any; minutes: any }) {
  const srv = getServer(srvName);
  const sections: string[] = [];
  const m = Math.max(1, Math.min(60, minutes));

  const [
    queueResult,
    sshBatchResult,
    dnsResults,
  ] = await Promise.all([
    serverQueue(srv, srvName),

    sshExec(srv.sshAlias, [
      `echo "===SERVER_LOGS==="`,
      `docker logs ${srv.container} --since ${m}m 2>&1 | grep -iE "queue|relay|delivery|bounce|reject|error|fail|next-hop|remote|connect" | tail -30`,
      `echo "===HTTP_TO_SMTP_PROXY_API_LOGS==="`,
      `docker logs http-to-smtp-proxy-api --since ${m}m 2>&1 | tail -20`,
      `echo "===OCI_RELAY==="`,
      `echo QUIT | timeout 5 openssl s_client -starttls smtp -connect smtp.email.eu-marseille-1.oci.oraclecloud.com:587 -quiet 2>&1 | head -3`,
      `echo "===AWS_RELAY==="`,
      `echo QUIT | timeout 5 openssl s_client -starttls smtp -connect email-smtp.us-east-1.amazonaws.com:587 -quiet 2>&1 | head -3`,
    ].join(" ; "), 30000),

    Promise.all([
      digExec(`MX ${DOMAIN}`),
      digExec(`TXT ${DOMAIN}`),
      digExec(`TXT default._domainkey.${DOMAIN}`),
      digExec(`TXT _dmarc.${DOMAIN}`),
    ]),
  ]);

  const sshSections: Record<string, string> = {};
  if (!isFail(sshBatchResult)) {
    const parts = sshBatchResult.split(/===(\w+)===/);
    for (let i = 1; i < parts.length; i += 2) {
      sshSections[parts[i]] = (parts[i + 1] ?? "").trim();
    }
  }

  // -- Section 1: Queue
  const queueOk = !isFail(queueResult) && !queueResult.includes("QUEUE_FAIL");
  const queueEmpty = queueResult === "Queue empty" || queueResult.trim() === "";
  sections.push([
    `== 1. ${srvName} Queue ${status(queueOk)} ==`,
    queueEmpty ? "  Queue is empty (no stuck messages)" : queueResult,
  ].join("\n"));

  // -- Section 2: Server Logs
  const serverLogs = isFail(sshBatchResult) ? sshBatchResult : (sshSections["SERVER_LOGS"] || "(no matching log lines)");
  const logsHaveErrors = /error|fail|reject|bounce/i.test(serverLogs) && serverLogs !== "(no matching log lines)";
  sections.push([
    `== 2. ${srvName} Outbound Logs (${m}m) ${status(!logsHaveErrors && !isFail(sshBatchResult))} ==`,
    serverLogs || "(no matching log lines)",
  ].join("\n"));

  // -- Section 3: HTTP-to-SMTP Proxy API Logs
  const proxyLogs = isFail(sshBatchResult) ? sshBatchResult : (sshSections["HTTP_TO_SMTP_PROXY_API_LOGS"] || "(no log lines)");
  sections.push([
    `== 3. HTTP-to-SMTP Proxy API Logs (${m}m) ${status(!isFail(sshBatchResult))} ==`,
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

  const allOk = queueOk && !logsHaveErrors && ociOk && mxOk && spfOk && dkimOk && dmarcOk;
  const header = allOk
    ? `=== OUTBOUND DEBUG (${srvName}): ALL CHECKS PASSED ===`
    : `=== OUTBOUND DEBUG (${srvName}): ISSUES DETECTED ===`;

  return {
    content: [{
      type: "text",
      text: `${header}\n\n${sections.join("\n\n")}`,
    }],
  };
}

export async function handle_debug_inbound({ server: srvName, minutes }: { server: any; minutes: any }) {
  const srv = getServer(srvName);
  const sections: string[] = [];
  const m = Math.max(1, Math.min(60, minutes));

  const [
    dnsResults,
    cfWorkerResult,
    gcpSshResult,
    ociSshResult,
    queueResult,
    imapResult,
    shadowResult,
  ] = await Promise.all([
    digExec(`MX ${DOMAIN}`),

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

    sshExec("gcp-proxy", `docker logs caddy --since ${m}m 2>&1 | grep -iE ":25|layer4|smtp|l4" | tail -10`, 15000),

    sshExec(srv.sshAlias, [
      `echo "===SMTP_BANNER==="`,
      `echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`,
      `echo "===INBOUND_LOGS==="`,
      `docker logs ${srv.container} --since ${m}m 2>&1 | grep -iE "ingest|received|accept|reject|spam|junk|from=|to=|message|deliver|rcpt|envelope" | tail -20`,
      `echo "===ACCOUNT_CHECK==="`,
      ...(srvName === "maddy"
        ? [`docker exec ${srv.container} maddy creds list 2>/dev/null | grep -i "me@diegonmarcos" || echo "account not found"`]
        : [`docker logs ${srv.container} --since 60m 2>&1 | grep -iE "auth.*me@diegonmarcos|login.*me@diegonmarcos" | tail -3 || echo "no recent auth activity"`]),
    ].join(" ; "), 20000),

    serverQueue(srv, srvName),

    (async (): Promise<string> => {
      try {
        const count = await withImap(srvName, "me", async (client) => {
          const lock = await client.getMailboxLock("INBOX");
          try {
            const mb = client.mailbox;
            return mb ? mb.exists : 0;
          } finally {
            lock.release();
          }
        });
        return `INBOX contains ${count} message(s)`;
      } catch (e: any) {
        return `IMAP_FAIL: ${e.message?.split("\n")[0] ?? e}`;
      }
    })(),

    // Shadow delivery check
    sshExec(srv.sshAlias, `docker logs http-to-smtp-proxy-api --since ${m}m 2>&1 | grep -iE 'shadow|dual|stalwart|forward' | tail -10`, 15000),
  ]);

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
    `== 4. ${srvName} SMTP :25 Banner ${status(smtpOk)} ==`,
    `  ${smtpBanner}`,
  ].join("\n"));

  // -- Section 5: Inbound Logs
  const inboundLogs = isFail(ociSshResult) ? ociSshResult : (ociSections["INBOUND_LOGS"] || "(no matching log lines)");
  const inboundErrors = /reject|spam|junk|error|fail/i.test(inboundLogs) && inboundLogs !== "(no matching log lines)";
  sections.push([
    `== 5. ${srvName} Inbound Logs (${m}m) ${status(!inboundErrors && !isFail(ociSshResult))} ==`,
    inboundLogs || "(no matching log lines)",
  ].join("\n"));

  // -- Section 6: Queue
  const queueOk = !isFail(queueResult) && !queueResult.includes("API_ERROR");
  const queueEmpty = queueResult === "Queue empty";
  sections.push([
    `== 6. ${srvName} Queue ${status(queueOk)} ==`,
    queueEmpty ? "  Queue is empty" : queueResult,
  ].join("\n"));

  // -- Section 7: IMAP Store
  const imapOk = imapResult.startsWith("INBOX");
  sections.push([
    `== 7. IMAP Store (${srvName}) ${status(imapOk)} ==`,
    `  ${imapResult}`,
  ].join("\n"));

  // -- Section 8: Account Check
  const accountOut = isFail(ociSshResult) ? ociSshResult : (ociSections["ACCOUNT_CHECK"] || "(no output)");
  const accountOk = srvName === "maddy"
    ? (/me@diegonmarcos/.test(accountOut) && !/not found/.test(accountOut))
    : !isFail(ociSshResult);
  sections.push([
    `== 8. ${srvName} Account Check ${status(accountOk)} ==`,
    `  ${accountOut}`,
  ].join("\n"));

  // -- Section 9: Shadow Delivery
  const shadowHasData = shadowResult && !isFail(shadowResult) && shadowResult.trim().length > 0;
  sections.push([
    `== 9. Shadow Delivery (http-to-smtp-proxy-api) ${shadowHasData ? "[ACTIVE]" : "[NONE]"} ==`,
    shadowHasData ? shadowResult : "  (no shadow delivery logs in window)",
  ].join("\n"));

  const allOk = mxOk && smtpOk && !inboundErrors && queueOk && imapOk && accountOk;
  const header = allOk
    ? `=== INBOUND DEBUG (${srvName}): ALL CHECKS PASSED ===`
    : `=== INBOUND DEBUG (${srvName}): ISSUES DETECTED ===`;

  return {
    content: [{
      type: "text",
      text: `${header}\n\n${sections.join("\n\n")}`,
    }],
  };
}

export async function handle_debug_trace({ server: srvName, message_id, sender, minutes, direction }: { server: any; message_id: any; sender: any; minutes: any; direction: any }) {
  const srv = getServer(srvName);
  const m = Math.max(1, Math.min(120, minutes));

  const grepParts: string[] = [];
  if (message_id) grepParts.push(message_id.replace(/[<>]/g, ""));
  if (sender) grepParts.push(sender);
  const grepFilter = grepParts.length > 0
    ? ` | grep -iE '${grepParts.join("|")}'`
    : "";

  const [caddyLogs, smtpProxyLogs, serverInbound, serverOutbound, queueStatus, ociRelay, imapCheck] = await Promise.all([
    (direction === "outbound" ? Promise.resolve("") :
      sshExec("gcp-proxy",
        `docker logs caddy --since ${m}m 2>&1 | grep -iE 'smtp|:25|:465|:587|layer4|l4|mail'${grepFilter} | tail -25`,
        20000)),

    (direction === "outbound" ? Promise.resolve("") :
      sshExec(srv.sshAlias,
        `docker logs http-to-smtp-proxy-api --since ${m}m 2>&1${grepFilter || " | tail -30"}`,
        15000)),

    (direction === "outbound" ? Promise.resolve("") :
      sshExec(srv.sshAlias,
        `docker logs ${srv.container} --since ${m}m 2>&1 | grep -iE 'ingest|received|accept|reject|spam|deliver|rcpt|envelope|from=|to=|check|spf|dkim|dmarc|dnsbl|xclient'${grepFilter} | tail -40`,
        20000)),

    (direction === "inbound" ? Promise.resolve("") :
      sshExec(srv.sshAlias,
        `docker logs ${srv.container} --since ${m}m 2>&1 | grep -iE 'queue|relay|remote|next-hop|delivery|bounce|submit|outbound|target\\.smtp'${grepFilter} | tail -40`,
        20000)),

    serverQueue(srv, srvName),

    (direction === "inbound" ? Promise.resolve("") :
      sshExec(srv.sshAlias,
        `echo QUIT | timeout 5 openssl s_client -starttls smtp -connect smtp.email.eu-marseille-1.oci.oraclecloud.com:587 -quiet 2>&1 | head -3`,
        15000)),

    (message_id ? (async () => {
      try {
        const result = await withImap(srvName, "me", async (client) => {
          const lock = await client.getMailboxLock("INBOX");
          try {
            const searchResult = await client.search({ header: { "message-id": message_id } });
            const msgs = Array.isArray(searchResult) ? searchResult : [];
            return msgs.length > 0 ? `FOUND in INBOX (${msgs.length} match)` : "NOT in INBOX";
          } finally {
            lock.release();
          }
        });
        return result;
      } catch (e: any) {
        return `IMAP_FAIL: ${e.message?.split("\n")[0] ?? e}`;
      }
    })() : Promise.resolve("")),
  ]);

  // ── Format output ──
  const sections: string[] = [];
  const trace = message_id ? `Message-ID: ${message_id}` : `Time window: last ${m} minutes`;
  const filter = sender ? ` | Sender: ${sender}` : "";

  sections.push(`=== MAIL TRACE (${srvName}): ${direction.toUpperCase()} ===\n${trace}${filter}`);

  if (direction !== "outbound") {
    sections.push([
      "── Inbound Flow ──────────────────────────────────────",
      "  Internet → CF Email Routing → CF Worker (email-forwarder)",
      "    → api.diegonmarcos.com/http-to-smtp-proxy-api (CF → Caddy on gcp-proxy → HTTP:8090)",
      `      → ${srvName} :25 (XCLIENT + SPF/DKIM/DMARC/DNSBL)`,
      "        → IMAP store (imapsql)",
    ].join("\n"));
  }
  if (direction !== "inbound") {
    sections.push([
      "── Outbound Flow ─────────────────────────────────────",
      `  ${srvName} submission :465/:587 (auth + DKIM sign)`,
      "    → OCI relay (smtp.email.eu-marseille-1.oci.oraclecloud.com:587)",
      "      → OCI DKIM sign (oci-mrs-202604) → recipient MX",
    ].join("\n"));
  }

  if (direction !== "outbound") {
    const hasData = caddyLogs && !isFail(caddyLogs) && caddyLogs.trim().length > 0;
    sections.push([
      `── 1. Caddy L4 (gcp-proxy) ${status(!isFail(caddyLogs))} ──`,
      hasData ? caddyLogs : "  (no SMTP passthrough logs in window)",
    ].join("\n"));
  }

  if (direction !== "outbound") {
    const hasData = smtpProxyLogs && !isFail(smtpProxyLogs) && smtpProxyLogs.trim().length > 0;
    const authFail = /401|Unauthorized|AUTH FAILED/i.test(smtpProxyLogs);
    const deliverOk = /Delivered OK|200|delivered/i.test(smtpProxyLogs);
    const badge = isFail(smtpProxyLogs) ? "[FAIL]"
      : authFail ? "[AUTH_FAIL]"
      : deliverOk ? "[PASS]"
      : "[INFO]";
    sections.push([
      `── 2. http-to-smtp-proxy-api (gcp-proxy:8090) ${badge} ──`,
      hasData ? smtpProxyLogs : "  (no logs in window)",
    ].join("\n"));
  }

  if (direction !== "outbound") {
    const hasData = serverInbound && !isFail(serverInbound) && serverInbound.trim().length > 0;
    const rejected = /reject|spam|junk/i.test(serverInbound);
    const badge = isFail(serverInbound) ? "[FAIL]"
      : rejected ? "[REJECTED]"
      : "[PASS]";
    sections.push([
      `── 3. ${srvName} Inbound (${srv.sshAlias}:25) ${badge} ──`,
      hasData ? serverInbound : "  (no inbound activity in window)",
    ].join("\n"));
  }

  if (direction !== "inbound") {
    const hasData = serverOutbound && !isFail(serverOutbound) && serverOutbound.trim().length > 0;
    const bounced = /bounce|fail|error/i.test(serverOutbound);
    const badge = isFail(serverOutbound) ? "[FAIL]"
      : bounced ? "[BOUNCE]"
      : "[PASS]";
    sections.push([
      `── 4. ${srvName} Outbound (queue → OCI relay) ${badge} ──`,
      hasData ? serverOutbound : "  (no outbound activity in window)",
    ].join("\n"));
  }

  const queueEmpty = /Queue empty|No queue activity/i.test(queueStatus) || queueStatus.trim() === "";
  sections.push([
    `── 5. ${srvName} Queue ${status(!isFail(queueStatus))} ──`,
    queueEmpty ? "  Queue empty (no stuck messages)" : queueStatus,
  ].join("\n"));

  if (direction !== "inbound") {
    const ociOk = /250|220|SMTP/i.test(ociRelay);
    sections.push([
      `── 6. OCI Relay ${status(ociOk)} ──`,
      ociRelay || "  (skipped)",
    ].join("\n"));
  }

  if (message_id && imapCheck) {
    const found = imapCheck.includes("FOUND");
    sections.push([
      `── 7. IMAP Delivery (${srvName}) ${status(found)} ──`,
      `  ${imapCheck}`,
    ].join("\n"));
  }

  return {
    content: [{
      type: "text",
      text: sections.join("\n\n"),
    }],
  };
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
      server: serverSchema,
      minutes: z.number().default(5).describe("How many minutes of logs to check (default 5)"),
    },
    handle_debug_outbound,
  );

  // ══════════════════════════════════════════════════════════════════
  // Tool 2: debug_inbound
  // ══════════════════════════════════════════════════════════════════
  server.tool(
    "debug_inbound",
    "Debug inbound mail delivery -- traces the full receive path with logs",
    {
      server: serverSchema,
      minutes: z.number().default(10).describe("How many minutes of logs to check (default 10)"),
    },
    handle_debug_inbound,
  );

  // ══════════════════════════════════════════════════════════════════
  // Tool 3: debug_trace — Consolidated mail flow trace
  // ══════════════════════════════════════════════════════════════════
  server.tool(
    "debug_trace",
    "Trace a message across the full mail pipeline — correlates logs from Cloudflare Worker, Caddy L4, http-to-smtp-proxy-api, mail server, and OCI relay. Use message_id for a specific message or minutes for a time window.",
    {
      server: serverSchema,
      message_id: z.string().optional().describe("Message-ID header value to trace (without angle brackets)"),
      sender: z.string().optional().describe("Sender email to filter by"),
      minutes: z.number().default(15).describe("Time window in minutes (default 15)"),
      direction: z.enum(["inbound", "outbound", "both"]).default("both").describe("Filter by mail direction"),
    },
    handle_debug_trace,
  );
}
