/**
 * Structured audit logging for mutating operations.
 * All output goes to stderr (stdout is reserved for JSON-RPC).
 */
export function audit(tool: string, target: string, result: string): void {
  const ts = new Date().toISOString();
  process.stderr.write(`[cloud-infra] [AUDIT] ${ts} ${tool} ${target} → ${result}\n`);
}
