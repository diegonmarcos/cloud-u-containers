import { exec } from "./exec.js";
import { RUST_API_BASE } from "./paths.js";

export interface HttpResult {
  ok: boolean;
  status: number;
  data: unknown;
  raw: string;
  error?: string;
}

function httpRequest(
  method: string,
  url: string,
  body?: string,
  timeout?: number,
  extraHeaders?: Record<string, string>
): HttpResult {
  const args = [
    "-s", "-S",
    "-X", method,
    "-H", "Content-Type: application/json",
    "-w", "\n__HTTP_STATUS__%{http_code}",
  ];

  if (extraHeaders) {
    for (const [key, value] of Object.entries(extraHeaders)) {
      args.push("-H", `${key}: ${value}`);
    }
  }

  if (body && (method === "POST" || method === "PUT" || method === "PATCH")) {
    args.push("-d", body);
  }

  args.push(url);

  const result = exec("curl", args, { timeout: timeout ?? 30_000 });

  const output = result.stdout;
  const statusMatch = output.match(/__HTTP_STATUS__(\d+)$/);
  const httpStatus = statusMatch ? parseInt(statusMatch[1], 10) : 0;
  const raw = output.replace(/__HTTP_STATUS__\d+$/, "").trim();

  if (!result.ok && httpStatus === 0) {
    return {
      ok: false,
      status: 0,
      data: null,
      raw: "",
      error: result.stderr || "curl failed",
    };
  }

  let data: unknown = raw;
  try {
    data = JSON.parse(raw);
  } catch {
    // keep as string
  }

  return {
    ok: httpStatus >= 200 && httpStatus < 400,
    status: httpStatus,
    data,
    raw,
    error: httpStatus >= 400 ? `HTTP ${httpStatus}` : undefined,
  };
}

export function rustApiGet(endpoint: string, timeout?: number): HttpResult {
  return httpRequest("GET", `${RUST_API_BASE}${endpoint}`, undefined, timeout);
}

export function rustApiPost(endpoint: string, body?: string, timeout?: number): HttpResult {
  return httpRequest("POST", `${RUST_API_BASE}${endpoint}`, body, timeout);
}

export function httpGet(url: string, timeout?: number): HttpResult {
  return httpRequest("GET", url, undefined, timeout);
}

export function rawHttpRequest(
  method: string,
  url: string,
  body?: string,
  timeout?: number,
  extraHeaders?: Record<string, string>
): HttpResult {
  return httpRequest(method, url, body, timeout, extraHeaders);
}
