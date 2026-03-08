import { exec, type ExecResult } from "./exec.js";
import { getConfig, resolveVmId, getVmSshAlias } from "./config.js";
import { audit } from "./audit.js";
import { SSH_IDENTITY } from "./paths.js";

export function sshExec(
  vmNameOrAlias: string,
  command: string,
  timeout?: number
): ExecResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);
  const config = getConfig();
  const vmConfig = config.vms[vmId];

  // Use user@ip directly — prefer wg_ip (works on Android via Android WG app, and on desktop)
  const host = vmConfig?.wg_ip || vmConfig?.ip || alias;
  const user = vmConfig?.user || "ubuntu";
  const target = `${user}@${host}`;
  const sshArgs = [
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-i", SSH_IDENTITY,
    target, command,
  ];
  const effectiveTimeout = timeout ?? 30_000;

  let result = exec("ssh", sshArgs, { timeout: effectiveTimeout });

  // WG handshake recovery: after idle the first TCP SYN can get dropped
  // during re-negotiation (ECONNABORTED / exit 255). Retry once after a
  // short delay to let the handshake complete.
  if (!result.ok && result.exitCode === 255) {
    audit("ssh", `${alias}: connection failed (exit 255), retrying after 2s`, result.stderr.trim());
    exec("sleep", ["2"], { timeout: 3_000 });
    result = exec("ssh", sshArgs, { timeout: effectiveTimeout });
  }

  audit("ssh", `${alias}: "${command.slice(0, 120)}"`, `exit ${result.exitCode}`);
  return result;
}

export function checkVmReachable(vmNameOrAlias: string): ExecResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const vmConfig = config.vms[vmId];

  // ssh-keyscan: TCP connect + SSH handshake only — no auth, no PAM session
  // Avoids 55s+ delays caused by slow PAM session creation on some VMs
  return exec("ssh-keyscan", ["-T", "5", vmConfig.ip], {
    timeout: 10_000,
  });
}
