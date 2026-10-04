import type { AppConfig, SiteCfg } from '../config.js';

export function findSite(cfg: AppConfig, sid: string): SiteCfg | undefined {
  return cfg.sites.find((s) => s.id === sid);
}

export function originAllowed(site: SiteCfg, origin: string | undefined): boolean {
  if (!origin) return false;
  return site.origins.includes(origin);
}
