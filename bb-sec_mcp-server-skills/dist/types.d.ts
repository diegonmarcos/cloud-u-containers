export interface VmConfig {
    ip: string;
    user: string;
    method: "key" | "gcloud";
    ssh_alias?: string;
    gcloud_instance?: string;
    gcloud_zone?: string;
    description: string;
}
export interface ServiceConfig {
    category: "app" | "mic" | "sec" | "tools" | "cloud" | "data" | "fin" | "agi";
    vm: string;
    flake?: string;
    subfolder?: string;
    description: string;
    discovered?: boolean;
}
export interface InfraConfig {
    ssh_key: string;
    remote_base: string;
    vms: Record<string, VmConfig>;
    services: Record<string, ServiceConfig>;
}
