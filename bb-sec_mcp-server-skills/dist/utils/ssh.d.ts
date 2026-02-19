import { type ExecResult } from "./exec.js";
export declare function sshExec(vmNameOrAlias: string, command: string, timeout?: number): ExecResult;
export declare function checkVmReachable(vmNameOrAlias: string): ExecResult;
