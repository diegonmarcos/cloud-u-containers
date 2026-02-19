import type { InfraConfig, ServiceConfig } from "./types.js";
export declare function getConfig(): InfraConfig;
export declare function reloadConfig(): InfraConfig;
export declare function getDriftReport(): {
    onDiskOnly: string[];
    configOnly: string[];
};
export declare function getServiceFolder(name: string): string;
export declare function getServiceDir(name: string): string;
export declare function getVmSshAlias(vmId: string): string;
export declare function resolveVmId(nameOrAlias: string): string;
export declare function getServicesForVm(vmId: string): [string, ServiceConfig][];
