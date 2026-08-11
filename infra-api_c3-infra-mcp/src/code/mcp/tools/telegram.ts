// ── devops.telegram.* — dedicated operator channel ──
// Talks to Diego over Telegram via the dedicated @Cloud_bot_C3_Infra_bot.
// Token arrives via sops secrets.yaml → .secrets env_file → process.env.C3_TELEGRAM_BOT_TOKEN.
// This bot token is dedicated to this service — no other consumer polls it,
// so long-polling getUpdates here is safe. Chat id is data-driven via env
// (C3_TELEGRAM_CHAT_ID), not hardcoded, so it can be overridden per environment.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

const DEFAULT_CHAT_ID = "6431508617";

function chatId(): string {
  return process.env.C3_TELEGRAM_CHAT_ID ?? DEFAULT_CHAT_ID;
}

function botToken(): string | undefined {
  return process.env.C3_TELEGRAM_BOT_TOKEN;
}

function apiUrl(method: string): string {
  return `https://api.telegram.org/bot${botToken()}/${method}`;
}

async function sendMessage(text: string): Promise<{ ok: boolean; description?: string }> {
  const resp = await fetch(apiUrl("sendMessage"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId(), text }),
    signal: AbortSignal.timeout(15_000),
  });
  const data = await resp.json() as { ok: boolean; description?: string };
  return data;
}

interface TelegramUpdate {
  update_id: number;
  message?: { chat: { id: number }; text?: string };
}

async function getUpdates(offset: number, timeoutSeconds: number): Promise<TelegramUpdate[]> {
  const resp = await fetch(apiUrl("getUpdates"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ offset, timeout: timeoutSeconds }),
    signal: AbortSignal.timeout((timeoutSeconds + 10) * 1000),
  });
  const data = await resp.json() as { ok: boolean; result?: TelegramUpdate[]; description?: string };
  if (!data.ok) throw new Error(data.description ?? "getUpdates failed");
  return data.result ?? [];
}

export function registerTelegramTools(server: McpServer) {
  server.tool(
    "devops.telegram.send",
    "Send a message to the operator (Diego) over the dedicated @Cloud_bot_C3_Infra_bot Telegram channel.",
    {
      text: z.string().describe("Message text to send"),
    },
    async ({ text }) => {
      if (!botToken()) {
        return {
          content: [{ type: "text" as const, text: "C3_TELEGRAM_BOT_TOKEN is not set" }],
          isError: true,
        };
      }

      try {
        const result = await sendMessage(text);
        return {
          content: [{
            type: "text" as const,
            text: result.ok ? "Sent" : `Telegram error: ${result.description ?? "unknown error"}`,
          }],
          isError: !result.ok,
        };
      } catch (e) {
        return {
          content: [{ type: "text" as const, text: `Telegram send failed: ${e instanceof Error ? e.message : String(e)}` }],
          isError: true,
        };
      }
    }
  );

  server.tool(
    "devops.telegram.ask",
    "Send a question to the operator (Diego) over the dedicated @Cloud_bot_C3_Infra_bot Telegram channel, then wait for a reply (long-polling).",
    {
      question: z.string().describe("Question text to send"),
      timeout_seconds: z.number().int().positive().max(600).optional().describe("Max time to wait for a reply (default 120, max 600)"),
    },
    async ({ question, timeout_seconds }) => {
      if (!botToken()) {
        return {
          content: [{ type: "text" as const, text: "C3_TELEGRAM_BOT_TOKEN is not set" }],
          isError: true,
        };
      }

      const deadlineMs = Date.now() + (timeout_seconds ?? 120) * 1000;

      try {
        const sent = await sendMessage(question);
        if (!sent.ok) {
          return {
            content: [{ type: "text" as const, text: `Telegram error: ${sent.description ?? "unknown error"}` }],
            isError: true,
          };
        }

        // Skip stale updates: start polling from the latest update_id at call time.
        let offset = 0;
        try {
          const initial = await getUpdates(-1, 0);
          if (initial.length > 0) offset = initial[initial.length - 1].update_id + 1;
        } catch {
          // no prior updates, or getUpdates race — fall back to offset 0
        }

        const targetChatId = chatId();

        while (Date.now() < deadlineMs) {
          const remainingMs = deadlineMs - Date.now();
          const pollTimeoutSeconds = Math.max(1, Math.min(25, Math.floor(remainingMs / 1000)));

          const updates = await getUpdates(offset, pollTimeoutSeconds);
          for (const update of updates) {
            offset = update.update_id + 1;
            const message = update.message;
            if (message?.text && String(message.chat.id) === targetChatId) {
              return {
                content: [{ type: "text" as const, text: JSON.stringify({ replied: true, text: message.text }) }],
              };
            }
          }
        }

        const waited = timeout_seconds ?? 120;
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ replied: false, note: `timeout after ${waited}s` }) }],
        };
      } catch (e) {
        return {
          content: [{ type: "text" as const, text: `Telegram ask failed: ${e instanceof Error ? e.message : String(e)}` }],
          isError: true,
        };
      }
    }
  );
}
