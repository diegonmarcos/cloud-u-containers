import { exec, type ExecResult } from "./exec.js";
import { getConfig, resolveVmId, getVmSshAlias } from "../config.js";

export function sshExec(
  vmNameOrAlias: string,
  command: string,
  timeout?: number
): ExecResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  return exec("ssh", ["-o", "ConnectTimeout=10", alias, command], {
    timeout: timeout ?? 30_000,
  });
}

export function checkVmReachable(vmNameOrAlias: string): ExecResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  return exec("ssh", ["-o", "ConnectTimeout=5", alias, "echo ok"], {
    timeout: 10_000,
  });
}
