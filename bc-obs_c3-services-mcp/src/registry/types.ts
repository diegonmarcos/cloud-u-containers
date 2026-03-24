export type ApiType = "openapi" | "custom-rest" | "custom-protocol" | "no-api";

export interface ApiCapability {
  type: ApiType;
  specUrl?: string;
  endpointCount: number;
  description: string;
}

export interface ServiceDefinition {
  name: string;
  displayName: string;
  description: string;
  vm: string;
  wgIp: string;
  port: number;
  domain?: string;
  api: ApiCapability;
}
