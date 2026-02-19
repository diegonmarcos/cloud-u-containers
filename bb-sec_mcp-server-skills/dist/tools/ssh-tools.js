import { z } from "zod";
import { sshExec, checkVmReachable } from "../utils/ssh.js";
import { getConfig, resolveVmId, getVmSshAlias } from "../config.js";
export function registerSshTools(server) {
    server.tool("ssh_exec", "Execute a command on a VM via SSH", {
        vm: z.string().describe("VM ID or SSH alias"),
        command: z.string().describe("Command to execute"),
        timeout: z.number().optional().describe("Timeout in ms (default: 30000)"),
    }, async ({ vm, command, timeout }) => {
        const vmId = resolveVmId(vm);
        const result = sshExec(vmId, command, timeout);
        return {
            content: [
                {
                    type: "text",
                    text: [
                        `SSH ${getVmSshAlias(vmId)} (${vmId}): ${result.ok ? "OK" : "FAILED"}`,
                        `Exit code: ${result.exitCode}`,
                        result.stdout ? `\n${result.stdout}` : "",
                        result.stderr ? `\nstderr: ${result.stderr}` : "",
                    ].join("\n"),
                },
            ],
            isError: !result.ok,
        };
    });
    server.tool("check_vm", "Test if a VM is reachable via SSH, optionally with system info", {
        vm: z.string().describe("VM ID or SSH alias"),
        detailed: z.boolean().optional().describe("Include system info (uptime, memory, disk)"),
    }, async ({ vm, detailed }) => {
        const vmId = resolveVmId(vm);
        const alias = getVmSshAlias(vmId);
        const config = getConfig();
        const vmConfig = config.vms[vmId];
        const ping = checkVmReachable(vmId);
        if (!ping.ok) {
            return {
                content: [
                    {
                        type: "text",
                        text: `${alias} (${vmId}) @ ${vmConfig.ip}: UNREACHABLE\n${ping.stderr}`,
                    },
                ],
                isError: true,
            };
        }
        if (!detailed) {
            return {
                content: [
                    { type: "text", text: `${alias} (${vmId}) @ ${vmConfig.ip}: REACHABLE` },
                ],
            };
        }
        const info = sshExec(vmId, 'echo "=== Uptime ===" && uptime && echo "=== Memory ===" && free -h && echo "=== Disk ===" && df -h / && echo "=== Docker ===" && docker ps --format "table {{.Names}}\\t{{.Status}}" 2>/dev/null || echo "Docker not available"', 15_000);
        return {
            content: [
                {
                    type: "text",
                    text: `${alias} (${vmId}) @ ${vmConfig.ip}: REACHABLE\n\n${info.stdout}`,
                },
            ],
        };
    });
}
//# sourceMappingURL=ssh-tools.js.map