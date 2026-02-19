export interface ExecResult {
    stdout: string;
    stderr: string;
    exitCode: number;
    ok: boolean;
}
export declare function exec(command: string, args: string[], options?: {
    timeout?: number;
    cwd?: string;
}): ExecResult;
