import { exec, execAsync, type ExecResult } from "./exec.js";
import { resolveVmId, getVmSshAlias } from "./config.js";
import { audit } from "./audit.js";

// ── SSH via alias ──────────────────────────────────────────────────
// All connection logic (host, user, key, ProxyJump, mux) lives in
// ~/.ssh/config. MCP tools just run `ssh <alias> <command>`.
// No custom IP resolution, no WG retry, no mux management.

export function sshExec(
  vmNameOrAlias: string,
  command: string,
  timeout?: number,
  _noRetry = false,
  connectTimeout = 10,
): ExecResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const sshArgs = [
    "-o", "BatchMode=yes",
    "-o", `ConnectTimeout=${connectTimeout}`,
    alias, command,
  ];
  const effectiveTimeout = timeout ?? 30_000;

  const result = exec("ssh", sshArgs, { timeout: effectiveTimeout });

  audit("ssh", `${alias}: "${command.slice(0, 120)}"`, `exit ${result.exitCode}`);
  return result;
}

export async function sshExecAsync(
  vmNameOrAlias: string,
  command: string,
  timeout?: number,
  _noRetry = false,
  connectTimeout = 10,
): Promise<ExecResult> {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const sshArgs = [
    "-o", "BatchMode=yes",
    "-o", `ConnectTimeout=${connectTimeout}`,
    alias, command,
  ];
  const effectiveTimeout = timeout ?? 30_000;

  const result = await execAsync("ssh", sshArgs, { timeout: effectiveTimeout });

  audit("ssh", `${alias}: "${command.slice(0, 120)}"`, `exit ${result.exitCode}`);
  return result;
}

export function checkVmReachable(vmNameOrAlias: string): ExecResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  // Quick SSH check — relies on ~/.ssh/config for host/key resolution
  return exec("ssh", [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    alias, "echo ok",
  ], { timeout: 10_000 });
}
