import { exec, type ExecResult } from "./exec.js";
import { getConfig, resolveVmId, getVmSshAlias } from "./config.js";
import { audit } from "./audit.js";

export function sshExec(
  vmNameOrAlias: string,
  command: string,
  timeout?: number
): ExecResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);
  const config = getConfig();
  const vmConfig = config.vms[vmId];

  // Use user@ip directly — no SSH config needed inside Docker
  const host = vmConfig?.wg_ip || vmConfig?.ip || alias;
  const user = vmConfig?.user || "ubuntu";
  const target = `${user}@${host}`;

  const result = exec("ssh", [
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-i", "/root/.ssh/vault_id_rsa",
    target, command,
  ], {
    timeout: timeout ?? 30_000,
  });

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
