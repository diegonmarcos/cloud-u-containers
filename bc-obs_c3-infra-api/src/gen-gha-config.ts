import { getConfig } from './shared/config.js';
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { SOLUTIONS_DIR } from './shared/paths.js';
const config = getConfig();
const vms: Record<string, any> = {};
for (const [vmId, vm] of Object.entries(config.vms)) {
  const v = vm as any;
  if (!v.ssh_alias || !v.gha) continue;
  vms[v.ssh_alias] = {
    ssh_secret: v.gha.ssh_secret,
    ...(v.gha.host_literal ? { host: v.ip, user: v.user } : {}),
    ...(v.gha.host_secret ? { host_secret: v.gha.host_secret, user_secret: v.gha.user_secret } : {}),
  };
}
const services: Record<string, any> = {};
for (const [name, svc] of Object.entries(config.services)) {
  const s = svc as any;
  const folder = s.folder;
  if (!folder) continue;
  const bjPath = join(SOLUTIONS_DIR, folder, 'build.json');
  if (!existsSync(bjPath)) continue;
  try {
    const bj = JSON.parse(readFileSync(bjPath, 'utf-8'));
    const host = bj.deploy?.host;
    if (!host || host === 'local' || host === 'all') continue;
    if (bj.frozen) continue;
    services[name] = { dir: folder, vm: host, has_docker: !!bj.docker };
  } catch { continue; }
}
console.log(JSON.stringify({ _generated: new Date().toISOString(), _source: 'local tsx via getConfig()', vms, services }, null, 2));
