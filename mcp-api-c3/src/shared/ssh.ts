import { exec, type ExecResult } from "./exec.js";
import { getConfig, resolveVmId, getVmSshAlias } from "./config.js";
import { audit } from "./audit.js";
import { SSH_IDENTITY } from "./paths.js";
import { mkdirSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

// SSH multiplexing — reuse connections to avoid repeated handshakes
const CONTROL_DIR = join(tmpdir(), "mcp-ssh-mux");
try { mkdirSync(CONTROL_DIR, { recursive: true, mode: 0o700 }); } catch {}

function controlPath(alias: string): string {
  return join(CONTROL_DIR, alias);
}

function ensureMux(alias: string, target: string): void {
  // Check if master is alive
  const check = exec("ssh", [
    "-o", `ControlPath=${controlPath(alias)}`,
    "-O", "check", target,
  ], { timeout: 3_000 });
  if (check.ok) return; // already running

  // Start master in background
  exec("ssh", [
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", `ControlMaster=auto`,
    "-o", `ControlPath=${controlPath(alias)}`,
    "-o", "ControlPersist=300",
    "-i", SSH_IDENTITY,
    "-fN", target,
  ], { timeout: 15_000 });
}

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

  // Establish multiplexed connection
  ensureMux(alias, target);

  const sshArgs = [
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", `ControlPath=${controlPath(alias)}`,
    "-i", SSH_IDENTITY,
    target, command,
  ];
  const effectiveTimeout = timeout ?? 30_000;

  let result = exec("ssh", sshArgs, { timeout: effectiveTimeout });

  // WG handshake recovery: if mux master died, retry with fresh connection
  if (!result.ok && result.exitCode === 255) {
    audit("ssh", `${alias}: connection failed (exit 255), re-establishing mux`, result.stderr.trim());
    exec("sleep", ["2"], { timeout: 3_000 });
    ensureMux(alias, target);
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
