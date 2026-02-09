import { spawnSync } from "child_process";
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
