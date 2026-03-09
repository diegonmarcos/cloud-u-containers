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

function killMux(alias: string, target: string): void {
  exec("ssh", [
    "-o", `ControlPath=${controlPath(alias)}`,
    "-O", "exit", target,
  ], { timeout: 3_000 });
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

function tcpProbe(host: string): { reachable: boolean; detail: string } {
  const result = exec("ssh-keyscan", ["-T", "5", host], { timeout: 10_000 });
  if (result.ok && result.stdout.trim().length > 0) {
    return { reachable: true, detail: "TCP probe: host reachable (SSH port open)" };
  }
  return { reachable: false, detail: "TCP probe: host unreachable (SSH port closed or filtered)" };
}

const WG_RETRY_DELAYS = [2, 3, 4]; // seconds between attempts

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
  const maxAttempts = WG_RETRY_DELAYS.length + 1; // first attempt + retries

  let result = exec("ssh", sshArgs, { timeout: effectiveTimeout });

  // WG handshake recovery: retry with escalating backoff
  for (let attempt = 1; attempt < maxAttempts && !result.ok && result.exitCode === 255; attempt++) {
    const delay = WG_RETRY_DELAYS[attempt - 1];
    audit("ssh", `${alias}: WG handshake attempt ${attempt}/${maxAttempts - 1}`, result.stderr.trim());
    killMux(alias, target);
    exec("sleep", [String(delay)], { timeout: (delay + 1) * 1_000 });
    ensureMux(alias, target);
    result = exec("ssh", sshArgs, { timeout: effectiveTimeout });
  }

  // Final failure: TCP probe to diagnose connectivity
  if (!result.ok && result.exitCode === 255) {
    const probe = tcpProbe(host);
    audit("ssh", `${alias}: all ${maxAttempts} attempts failed — ${probe.detail}`, result.stderr.trim());
    result = {
      ...result,
      stderr: `${result.stderr}\n[ssh] ${maxAttempts} WG handshake attempts failed for ${alias}. ${probe.detail}`,
    };
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
