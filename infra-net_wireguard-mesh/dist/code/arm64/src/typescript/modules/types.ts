// Domain types — wireguard-mesh
// Mirrors the schema emitted by 9_others/src/engine/derive-mesh-snapshot.ts
// (wg-mesh/v1).

export type NodeRole = 'hub' | 'spoke' | 'client';

export interface Node {
  name: string;
  role: NodeRole;
  alias?: string;
  public_ip: string;
  wg_ip: string;
  region: string;
  provider: string;
  os: string;
  public_key_fp?: string;
  ports_public?: string[];
  wstunnel_server?: boolean;
  wstunnel_client?: boolean;
}

export interface Peer {
  from: string;
  to: string;
  allowed_ips: string[];
  persistent_keepalive: number;
}

export interface Transport {
  name: string;
  label: string;
  protocol: 'udp' | 'tcp';
  port: number;
  endpoint: string;
  primary: boolean;
  fallback: boolean;
  active_peers?: number;
  use_case?: string;
}

export interface Route {
  src_node: string;
  dst_subnet: string;
  via_transport: string;
  comment?: string;
}

export interface TlsExpiry { host: string; expires_at: string; issuer?: string }
export interface Health    { tls_expiries: TlsExpiry[]; last_snapshot_at: string; status: 'healthy' | 'degraded' | 'down' }

export interface Snapshot {
  _meta: { generated_at: string; generated_by: string; schema: string; snapshot_age_seconds?: number };
  nodes:      Node[];
  peers:      Peer[];
  transports: Transport[];
  routes:     Route[];
  health:     Health;
}

export interface Route2 { path: string; params: Record<string, string> }
export interface AppState { route: Route2; snapshot: Snapshot | null }
