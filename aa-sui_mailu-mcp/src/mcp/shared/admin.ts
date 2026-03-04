import { execSync } from "child_process";

function isOnMailVm(): boolean {
  // If running inside Docker on oci-mail, /proc/1/cgroup shows docker
  try {
    const cgroup = execSync("cat /proc/1/cgroup 2>/dev/null || echo ''", { encoding: "utf8" });
    return cgroup.includes("docker");
  } catch {
    return false;
  }
}

/**
 * Run a `flask mailu` CLI command.
 * - On oci-mail Docker: `docker exec mailu-admin-1 flask mailu <args>`
 * - Locally (Termux/desktop): `ssh oci-mail docker exec mailu-admin-1 flask mailu <args>`
 */
export function flaskMailu(args: string): string {
  const baseCmd = `docker exec mailu-admin-1 flask mailu ${args}`;
  const cmd = isOnMailVm() ? baseCmd : `ssh oci-mail '${baseCmd}'`;
  return execSync(cmd, { encoding: "utf8", timeout: 15000 });
}
