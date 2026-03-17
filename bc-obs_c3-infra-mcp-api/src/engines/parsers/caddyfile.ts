import { readFileSync, existsSync } from "fs";
import { join } from "path";

export interface CaddyRoute {
  domain: string;
  upstream: string;
  auth: "none" | "authelia" | "authelia+bearer" | "3-tier";
  tls_skip: boolean;
  public_paths: string[];
}

export function parseCaddyfile(solutionsDir: string): CaddyRoute[] {
  const caddyfilePath = join(solutionsDir, "bb-sec_caddy", "dist", "Caddyfile");
  if (!existsSync(caddyfilePath)) return [];

  const content = readFileSync(caddyfilePath, "utf-8");
  const routes: CaddyRoute[] = [];
  const lines = content.split("\n");

  let i = 0;
  while (i < lines.length) {
    // Match domain block: `  domain.com {` or `  domain.com, www.domain.com {`
    const domainMatch = lines[i].match(/^\s+([\w.*-]+\.diegonmarcos\.com(?:,\s*[\w.*-]+\.diegonmarcos\.com)*)\s*\{/);
    if (!domainMatch) {
      i++;
      continue;
    }

    const domainRaw = domainMatch[1].split(",")[0].trim();

    // Skip wildcard catch-all
    if (domainRaw === "*.diegonmarcos.com") {
      i++;
      continue;
    }

    // Collect block content until matching closing brace
    let depth = 1;
    let blockStart = i;
    i++;
    const blockLines: string[] = [];
    while (i < lines.length && depth > 0) {
      const line = lines[i];
      for (const ch of line) {
        if (ch === "{") depth++;
        if (ch === "}") depth--;
      }
      if (depth > 0) blockLines.push(line);
      i++;
    }

    const block = blockLines.join("\n");

    // Find primary reverse_proxy target (skip error handlers)
    const upstreams: string[] = [];
    for (const line of blockLines) {
      const trimmed = line.trim();
      if (trimmed.startsWith("reverse_proxy") && !trimmed.includes("error")) {
        const target = trimmed
          .replace(/^reverse_proxy\s+/, "")
          .replace(/\s*\{.*$/, "")
          .trim();
        if (target && !target.startsWith("https://diegonmarcos.github.io")) {
          upstreams.push(target);
        }
      }
    }

    // Skip GitHub Pages proxies (static sites, not real upstreams)
    if (block.includes("diegonmarcos.github.io") && upstreams.length === 0) {
      continue;
    }

    const upstream = upstreams[0] || "static";

    // Detect auth type
    let auth: CaddyRoute["auth"] = "none";
    if (block.includes("@authelia_jwt") && block.includes("@ntfy_token")) {
      auth = "3-tier";
    } else if (block.includes("introspect-proxy") && block.includes("forward_auth authelia")) {
      auth = "authelia+bearer";
    } else if (block.includes("forward_auth authelia")) {
      auth = "authelia";
    }

    // Detect TLS skip
    const tls_skip = block.includes("tls_insecure_skip_verify");

    // Detect public paths
    const public_paths: string[] = [];
    const trackingMatch = block.match(/path\s+((?:\/[\w.*-]+\s*)+)/g);
    if (trackingMatch && (block.includes("@tracking") || block.includes("@root"))) {
      for (const m of trackingMatch) {
        const paths = m.replace(/^path\s+/, "").trim().split(/\s+/);
        public_paths.push(...paths);
      }
    }

    // For api.diegonmarcos.com, extract sub-routes
    if (domainRaw === "api.diegonmarcos.com") {
      const subRoutes = extractApiSubRoutes(blockLines);
      routes.push(...subRoutes);
      continue;
    }

    // For app.diegonmarcos.com, extract sub-routes
    if (domainRaw === "app.diegonmarcos.com") {
      const subRoutes = extractAppSubRoutes(blockLines);
      routes.push(...subRoutes);
      continue;
    }

    routes.push({
      domain: domainRaw,
      upstream: upstream.replace(/^https?:\/\//, ""),
      auth,
      tls_skip,
      public_paths,
    });
  }

  return routes;
}

function extractApiSubRoutes(lines: string[]): CaddyRoute[] {
  const routes: CaddyRoute[] = [];
  const seen = new Set<string>();

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    // handle_path /prefix/* { ... reverse_proxy target }
    const handlePath = line.match(/handle_path\s+\/([\w-]+)\/\*\s*\{/);
    if (handlePath) {
      const prefix = handlePath[1];
      if (seen.has(prefix)) continue;
      seen.add(prefix);

      // Find reverse_proxy in this block
      let depth = 1;
      let j = i + 1;
      let target = "";
      let hasBearer = false;
      while (j < lines.length && depth > 0) {
        const l = lines[j].trim();
        for (const ch of lines[j]) { if (ch === "{") depth++; if (ch === "}") depth--; }
        if (l.startsWith("reverse_proxy") && !target) {
          target = l.replace(/^reverse_proxy\s+/, "").replace(/\s*\{.*$/, "").trim();
        }
        if (l.includes("@bearer") || l.includes("introspect-proxy")) hasBearer = true;
        j++;
      }

      if (target) {
        routes.push({
          domain: `api.diegonmarcos.com/${prefix}`,
          upstream: target.replace(/^https?:\/\//, ""),
          auth: hasBearer ? "authelia+bearer" : "none",
          tls_skip: false,
          public_paths: [],
        });
      }
    }
  }

  return routes;
}

function extractAppSubRoutes(lines: string[]): CaddyRoute[] {
  const routes: CaddyRoute[] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    const handlePath = line.match(/handle_path\s+\/([\w-]+)\/\*\s*\{/);
    if (handlePath) {
      const prefix = handlePath[1];
      let depth = 1;
      let j = i + 1;
      let target = "";
      while (j < lines.length && depth > 0) {
        const l = lines[j].trim();
        for (const ch of lines[j]) { if (ch === "{") depth++; if (ch === "}") depth--; }
        if (l.startsWith("reverse_proxy") && !target) {
          target = l.replace(/^reverse_proxy\s+/, "").replace(/\s*\{.*$/, "").trim();
        }
        j++;
      }

      if (target) {
        routes.push({
          domain: `app.diegonmarcos.com/${prefix}`,
          upstream: target.replace(/^https?:\/\//, ""),
          auth: "authelia+bearer",
          tls_skip: false,
          public_paths: [],
        });
      }
    }
  }

  return routes;
}
