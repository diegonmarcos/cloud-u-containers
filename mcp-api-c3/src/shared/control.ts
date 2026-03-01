/**
 * VM / Container / Service lifecycle control.
 *
 * Replaces the Rust API's ondemand.rs — drives everything through CLI tools
 * (gcloud, oci) and SSH/Docker directly.
 */

import { sshExec, checkVmReachable } from "./ssh.js";
import { getConfig, resolveVmId, getVmSshAlias } from "./config.js";
import { exec } from "./exec.js";
import { audit } from "./audit.js";
import { controlContainer } from "./docker.js";
import { validateContainerName, validatePathComponent } from "./validators.js";

// ─── Result type ────────────────────────────────────────────────────────────

export interface ControlResult {
  ok: boolean;
  message: string;
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function ensureVmReachable(vmId: string): ControlResult | null {
  const check = checkVmReachable(vmId);
  if (!check.ok) {
    return {
      ok: false,
      message: `VM ${getVmSshAlias(vmId)} (${vmId}) is not reachable via SSH.`,
    };
  }
  return null;
}

// ─── VM lifecycle ───────────────────────────────────────────────────────────

export function vmStart(vmNameOrAlias: string): ControlResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const vm = config.vms[vmId];
  const alias = getVmSshAlias(vmId);

  if (vm.method === "gcloud") {
    if (!vm.gcloud_instance || !vm.gcloud_zone) {
      return {
        ok: false,
        message: `GCP VM ${alias} (${vmId}) missing gcloud_instance or gcloud_zone in config.`,
      };
    }
    const result = exec("gcloud", [
      "compute",
      "instances",
      "start",
      vm.gcloud_instance,
      "--zone",
      vm.gcloud_zone,
      "--format=json",
    ]);
    audit("vm_start", `${alias} (gcloud)`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);
    if (!result.ok) {
      return {
        ok: false,
        message: `Failed to start GCP VM ${alias}: ${result.stderr.trim() || result.stdout.trim()}`,
      };
    }
    return { ok: true, message: `GCP VM ${alias} start initiated.` };
  }

  // OCI VMs — no instance OCID in config, so we cannot use `oci compute instance action`.
  // Attempt SSH to check if already running; otherwise advise manual start.
  const reachable = checkVmReachable(vmId);
  if (reachable.ok) {
    audit("vm_start", `${alias} (oci)`, "ALREADY_RUNNING");
    return { ok: true, message: `OCI VM ${alias} is already running.` };
  }

  audit("vm_start", `${alias} (oci)`, "UNREACHABLE — manual start required");
  return {
    ok: false,
    message:
      `OCI VM ${alias} is not reachable. ` +
      `Start it manually from the OCI console or use: ` +
      `oci compute instance action --action START --instance-id <OCID>`,
  };
}

export function vmStop(vmNameOrAlias: string): ControlResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const vm = config.vms[vmId];
  const alias = getVmSshAlias(vmId);

  if (vm.method === "gcloud") {
    if (!vm.gcloud_instance || !vm.gcloud_zone) {
      return {
        ok: false,
        message: `GCP VM ${alias} (${vmId}) missing gcloud_instance or gcloud_zone in config.`,
      };
    }
    const result = exec("gcloud", [
      "compute",
      "instances",
      "stop",
      vm.gcloud_instance,
      "--zone",
      vm.gcloud_zone,
      "--format=json",
    ]);
    audit("vm_stop", `${alias} (gcloud)`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);
    if (!result.ok) {
      return {
        ok: false,
        message: `Failed to stop GCP VM ${alias}: ${result.stderr.trim() || result.stdout.trim()}`,
      };
    }
    return { ok: true, message: `GCP VM ${alias} stop initiated.` };
  }

  // OCI VMs — graceful shutdown via SSH
  const reachable = checkVmReachable(vmId);
  if (!reachable.ok) {
    audit("vm_stop", `${alias} (oci)`, "ALREADY_STOPPED");
    return { ok: true, message: `OCI VM ${alias} appears to be already stopped (unreachable).` };
  }

  const result = sshExec(vmId, "sudo shutdown -h now", 15_000);
  audit("vm_stop", `${alias} (oci/ssh)`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

  // shutdown command often returns non-zero because the connection drops
  return { ok: true, message: `OCI VM ${alias} shutdown command sent.` };
}

export function vmReset(vmNameOrAlias: string): ControlResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const vm = config.vms[vmId];
  const alias = getVmSshAlias(vmId);

  if (vm.method === "gcloud") {
    if (!vm.gcloud_instance || !vm.gcloud_zone) {
      return {
        ok: false,
        message: `GCP VM ${alias} (${vmId}) missing gcloud_instance or gcloud_zone in config.`,
      };
    }
    const result = exec("gcloud", [
      "compute",
      "instances",
      "reset",
      vm.gcloud_instance,
      "--zone",
      vm.gcloud_zone,
      "--format=json",
    ]);
    audit("vm_reset", `${alias} (gcloud)`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);
    if (!result.ok) {
      return {
        ok: false,
        message: `Failed to reset GCP VM ${alias}: ${result.stderr.trim() || result.stdout.trim()}`,
      };
    }
    return { ok: true, message: `GCP VM ${alias} reset initiated.` };
  }

  // OCI VMs — force reboot via SSH
  const reachable = checkVmReachable(vmId);
  if (!reachable.ok) {
    audit("vm_reset", `${alias} (oci)`, "UNREACHABLE — cannot reset");
    return {
      ok: false,
      message:
        `OCI VM ${alias} is not reachable. ` +
        `Reset it manually from the OCI console or use: ` +
        `oci compute instance action --action RESET --instance-id <OCID>`,
    };
  }

  const result = sshExec(vmId, "sudo reboot", 15_000);
  audit("vm_reset", `${alias} (oci/ssh)`, "SENT");

  // reboot command drops the connection, so non-zero exit is expected
  return { ok: true, message: `OCI VM ${alias} reboot command sent.` };
}

// ─── Container lifecycle ────────────────────────────────────────────────────

export function containerStart(
  vmNameOrAlias: string,
  containerName: string,
): ControlResult {
  validateContainerName(containerName);
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const unreachable = ensureVmReachable(vmId);
  if (unreachable) {
    audit("container_start", `${containerName}@${alias}`, "VM_UNREACHABLE");
    return unreachable;
  }

  const { ok, output } = controlContainer(vmId, containerName, "start");
  audit("container_start", `${containerName}@${alias}`, ok ? "OK" : "FAILED");
  return {
    ok,
    message: ok
      ? `Container ${containerName} started on ${alias}.`
      : `Failed to start ${containerName} on ${alias}: ${output.trim()}`,
  };
}

export function containerStop(
  vmNameOrAlias: string,
  containerName: string,
): ControlResult {
  validateContainerName(containerName);
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const unreachable = ensureVmReachable(vmId);
  if (unreachable) {
    audit("container_stop", `${containerName}@${alias}`, "VM_UNREACHABLE");
    return unreachable;
  }

  const { ok, output } = controlContainer(vmId, containerName, "stop");
  audit("container_stop", `${containerName}@${alias}`, ok ? "OK" : "FAILED");
  return {
    ok,
    message: ok
      ? `Container ${containerName} stopped on ${alias}.`
      : `Failed to stop ${containerName} on ${alias}: ${output.trim()}`,
  };
}

export function containerRestart(
  vmNameOrAlias: string,
  containerName: string,
): ControlResult {
  validateContainerName(containerName);
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const unreachable = ensureVmReachable(vmId);
  if (unreachable) {
    audit("container_restart", `${containerName}@${alias}`, "VM_UNREACHABLE");
    return unreachable;
  }

  const { ok, output } = controlContainer(vmId, containerName, "restart");
  audit("container_restart", `${containerName}@${alias}`, ok ? "OK" : "FAILED");
  return {
    ok,
    message: ok
      ? `Container ${containerName} restarted on ${alias}.`
      : `Failed to restart ${containerName} on ${alias}: ${output.trim()}`,
  };
}

// ─── Service lifecycle ──────────────────────────────────────────────────────

export function serviceStart(
  vmNameOrAlias: string,
  serviceName: string,
): ControlResult {
  validatePathComponent(serviceName);
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const alias = getVmSshAlias(vmId);

  const unreachable = ensureVmReachable(vmId);
  if (unreachable) {
    audit("service_start", `${serviceName}@${alias}`, "VM_UNREACHABLE");
    return unreachable;
  }

  const remotePath = `${config.remote_base}/${serviceName}`;
  const result = sshExec(vmId, `cd ${remotePath} && docker compose up -d`, 60_000);

  audit(
    "service_start",
    `${serviceName}@${alias}`,
    result.ok ? "OK" : `FAILED (exit ${result.exitCode})`,
  );

  const output = `${result.stdout}${result.stderr}`.trim();
  return {
    ok: result.ok,
    message: result.ok
      ? `Service ${serviceName} started on ${alias}.\n${output}`
      : `Failed to start service ${serviceName} on ${alias}: ${output}`,
  };
}

export function serviceStop(
  vmNameOrAlias: string,
  serviceName: string,
): ControlResult {
  validatePathComponent(serviceName);
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const alias = getVmSshAlias(vmId);

  const unreachable = ensureVmReachable(vmId);
  if (unreachable) {
    audit("service_stop", `${serviceName}@${alias}`, "VM_UNREACHABLE");
    return unreachable;
  }

  const remotePath = `${config.remote_base}/${serviceName}`;
  const result = sshExec(vmId, `cd ${remotePath} && docker compose down`, 60_000);

  audit(
    "service_stop",
    `${serviceName}@${alias}`,
    result.ok ? "OK" : `FAILED (exit ${result.exitCode})`,
  );

  const output = `${result.stdout}${result.stderr}`.trim();
  return {
    ok: result.ok,
    message: result.ok
      ? `Service ${serviceName} stopped on ${alias}.\n${output}`
      : `Failed to stop service ${serviceName} on ${alias}: ${output}`,
  };
}

// ─── Service restart ────────────────────────────────────────────────────

export function serviceRestart(
  vmNameOrAlias: string,
  serviceName: string,
): ControlResult {
  validatePathComponent(serviceName);
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const alias = getVmSshAlias(vmId);

  const unreachable = ensureVmReachable(vmId);
  if (unreachable) {
    audit("service_restart", `${serviceName}@${alias}`, "VM_UNREACHABLE");
    return unreachable;
  }

  const remotePath = `${config.remote_base}/${serviceName}`;
  const result = sshExec(vmId, `cd ${remotePath} && docker compose down && docker compose up -d`, 90_000);

  audit(
    "service_restart",
    `${serviceName}@${alias}`,
    result.ok ? "OK" : `FAILED (exit ${result.exitCode})`,
  );

  const output = `${result.stdout}${result.stderr}`.trim();
  return {
    ok: result.ok,
    message: result.ok
      ? `Service ${serviceName} restarted on ${alias}.\n${output}`
      : `Failed to restart service ${serviceName} on ${alias}: ${output}`,
  };
}

// ─── VM drain ───────────────────────────────────────────────────────────

export function vmDrain(vmNameOrAlias: string): ControlResult {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const unreachable = ensureVmReachable(vmId);
  if (unreachable) {
    audit("vm_drain", alias, "VM_UNREACHABLE");
    return unreachable;
  }

  const result = sshExec(vmId, "docker ps -q | xargs -r docker stop", 120_000);

  audit(
    "vm_drain",
    alias,
    result.ok ? "OK" : `FAILED (exit ${result.exitCode})`,
  );

  const output = `${result.stdout}${result.stderr}`.trim();
  return {
    ok: result.ok,
    message: result.ok
      ? `All containers stopped on ${alias}.\n${output}`
      : `Failed to drain ${alias}: ${output}`,
  };
}
