import { spawnSync, spawn } from "child_process";
import { SOPS_AGE_KEY_FILE } from "./paths.js";

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  ok: boolean;
}

export function exec(
  command: string,
  args: string[],
  options?: { timeout?: number; cwd?: string }
): ExecResult {
  const timeout = options?.timeout ?? 30_000;
  const result = spawnSync(command, args, {
    timeout,
    cwd: options?.cwd,
    encoding: "utf-8",
    env: {
      ...process.env,
      SOPS_AGE_KEY_FILE,
    },
    maxBuffer: 10 * 1024 * 1024,
  });

  return {
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    exitCode: result.status ?? 1,
    ok: result.status === 0,
  };
}

export function execAsync(
  command: string,
  args: string[],
  options?: { timeout?: number; cwd?: string }
): Promise<ExecResult> {
  const timeout = options?.timeout ?? 30_000;
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      cwd: options?.cwd,
      env: { ...process.env, SOPS_AGE_KEY_FILE },
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    proc.stdout.setEncoding("utf-8");
    proc.stderr.setEncoding("utf-8");
    proc.stdout.on("data", (d: string) => { stdout += d; });
    proc.stderr.on("data", (d: string) => { stderr += d; });

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        proc.kill("SIGTERM");
        setTimeout(() => { try { proc.kill("SIGKILL"); } catch {} }, 1_000);
        resolve({ stdout, stderr, exitCode: 1, ok: false });
      }
    }, timeout);

    proc.on("close", (code) => {
      clearTimeout(timer);
      if (!settled) {
        settled = true;
        resolve({ stdout, stderr, exitCode: code ?? 1, ok: code === 0 });
      }
    });

    proc.on("error", (err) => {
      clearTimeout(timer);
      if (!settled) {
        settled = true;
        resolve({ stdout, stderr: stderr + err.message, exitCode: 1, ok: false });
      }
    });
  });
}
