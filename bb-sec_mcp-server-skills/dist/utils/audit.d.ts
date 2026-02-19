/**
 * Structured audit logging for mutating operations.
 * All output goes to stderr (stdout is reserved for JSON-RPC).
 */
export declare function audit(tool: string, target: string, result: string): void;
