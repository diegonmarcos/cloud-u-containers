import { existsSync, readFileSync } from "fs";
import { execSync } from "child_process";
import { homedir } from "os";
import { join } from "path";

export const HOME = homedir();
export const GIT_BASE = process.env.GIT_BASE ?? join(HOME, "git");

// Android/Termux detection — WireGuard is managed by the Android WG app,
// so mesh IPs work. Key paths differ from desktop NixOS.
export const IS_ANDROID = process.env.ANDROID_DATA !== undefined
  || HOME.includes("com.termux");

// Server mode = Docker container on VM (repos are disposable clones).
// Client mode = local machine (Termux/desktop) where repos are working copies.
// In client mode, NEVER run destructive git ops — the user's working copy IS truth.
export const IS_SERVER = existsSync("/.dockerenv")
  || process.env.CONTAINER === "true"
  || process.env.MCP_SERVER_MODE === "true";
export const IS_CLIENT = !IS_SERVER;

// SSH identity key — find first available key across environments:
//   Docker container: ~/.ssh/vault_id_rsa (mounted from VM)
//   Android/Termux:   ~/.ssh/id_rsa (symlinked from vault)
//   Desktop NixOS:    vault/A0_keys/ssh/id_rsa
export const SSH_IDENTITY = [
  join(HOME, ".ssh/vault_id_rsa"),
  join(HOME, ".ssh/id_rsa"),
  join(HOME, ".ssh/id_ed25519"),
  join(GIT_BASE, "vault/A0_keys/ssh/id_rsa"),
].find((p) => existsSync(p)) ?? join(HOME, ".ssh/id_rsa");
export const SOLUTIONS_DIR = join(GIT_BASE, "cloud/a_solutions");

// CLOUD_DATA_DIR / CLOUD_DATA_REPO declared early so resolveCloudDataPath can
// reference them. Used as a legacy fallback path (the c3_git_repos volume clone).
export const CLOUD_DATA_DIR = join(GIT_BASE, "cloud-data");
export const CLOUD_DATA_REPO = "git@github.com:diegonmarcos/cloud-data.git";

// Cloud-data file resolution.
//
// 2026-04-27 migrated: cloud-data-{topology,configs,deps}.json → _cloud-data-consolidated.json[.{configs,deps}]
// All three deprecated split files are now slices of `_cloud-data-consolidated.json`:
//   - topology shape  → consolidated top-level (consolidated IS a superset of topology)
//   - configs slice   → consolidated.configs
//   - deps slice      → consolidated.deps
// Back-compat: getConfigPath / CONFIGS_PATH / DEPS_PATH all resolve to the
// consolidated file. Use getConfigsSlice() / getDepsSlice() / getTopologySlice()
// to pull the relevant nested key.
//
// 2026-04-27: priority puts IN-IMAGE bundled copies first — every container with
// `build.include_cloud_data: true` gets 1_cicd/dist/*.json copied into its
// image at /app/<filename>. Falls back to dev repo dist/, c3_git_repos clone,
// and cloud repo root for backwards compatibility.
// 2026-04-27 migrated: ENV var (CONFIG_JSON_PATH / CONFIG_PATH) overrides apply
// when the caller asks for the consolidated file (the new topology source) OR the
// legacy topology filename (back-compat for any external caller).
function resolveCloudDataPath(filename: string): string {
  const isTopology = filename === "_cloud-data-consolidated.json" || filename === "cloud-data-topology.json";
  if (isTopology && process.env.CONFIG_JSON_PATH) return process.env.CONFIG_JSON_PATH;
  if (isTopology && process.env.CONFIG_PATH) return process.env.CONFIG_PATH;
  const candidates = [
    `/app/${filename}`,                                            // bundled in-image (preferred)
    join(SOLUTIONS_DIR, "..", "9_others", "dist", filename),      // dev: cloud repo dist/
    join(CLOUD_DATA_DIR, filename),                                // legacy: c3_git_repos clone
    join(SOLUTIONS_DIR, "..", filename),                           // legacy: cloud repo root
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return candidates[0]; // best-guess for error paths
}

// 2026-04-27 migrated: cloud-data-topology.json → _cloud-data-consolidated.json
// Topology readers can keep reading `.services` / `.vms` etc. unchanged because
// consolidated is a superset of the old topology shape.
function resolveConfigPath(): string {
  if (process.env.CONFIG_JSON_PATH) return process.env.CONFIG_JSON_PATH;
  if (process.env.CONFIG_PATH) return process.env.CONFIG_PATH;
  const candidates = [
    `/app/_cloud-data-consolidated.json`,
    join(SOLUTIONS_DIR, "..", "9_others", "dist", "_cloud-data-consolidated.json"),
    join(CLOUD_DATA_DIR, "_cloud-data-consolidated.json"),
    join(SOLUTIONS_DIR, "..", "_cloud-data-consolidated.json"),
    `/app/cloud-data-topology.json`,                                                          // 2026-04-27 migrated: legacy fallback
    join(SOLUTIONS_DIR, "..", "9_others", "dist", "cloud-data-topology.json"),               // 2026-04-27 migrated: legacy fallback
    join(CLOUD_DATA_DIR, "cloud-data-topology.json"),                                          // 2026-04-27 migrated: legacy fallback
    join(SOLUTIONS_DIR, "..", "cloud-data-topology.json"),                                     // 2026-04-27 migrated: legacy fallback
    join(SOLUTIONS_DIR, "..", "config.json"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return join(SOLUTIONS_DIR, "..", "9_others", "dist", "_cloud-data-consolidated.json");
}

export { resolveConfigPath as getConfigPath, resolveCloudDataPath };
// Lazy getters so the path is re-resolved on each read (handles late-arriving
// cloud-data clones from syncRepos and the bundled in-image path equally).
// 2026-04-27 migrated: getConfigsPath/getDepsPath now point at the consolidated
// file instead of the deprecated split files. Use getConfigsSlice/getDepsSlice
// helpers below to extract the actual configs/deps payload.
export const getConsolidatedPath = () => resolveCloudDataPath("_cloud-data-consolidated.json");
export const getConfigsPath = () => getConsolidatedPath();
export const getDepsPath = () => getConsolidatedPath();
export const getOwnBuildPath = () => resolveCloudDataPath("build-c3-infra-api.json");
// Back-compat exports — call sites can still treat these as path strings.
// 2026-04-27 migrated: now resolve to _cloud-data-consolidated.json. Existing
// call sites that JSON.parse(readFileSync(CONFIGS_PATH))/(DEPS_PATH) and read a
// nested key MUST be updated to use the slice helpers below; call sites that
// only check `existsSync(path)` keep working.
export const CONFIGS_PATH = getConfigsPath();
export const DEPS_PATH = getDepsPath();

// ── Slice helpers — read consolidated and return the relevant nested key.
// 2026-04-27 migrated: replaces JSON.parse(readFileSync(CONFIGS_PATH/DEPS_PATH)).
function readConsolidated(): any {
  const path = getConsolidatedPath();
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    return null;
  }
}
export const getTopologySlice = (): any => readConsolidated() ?? {};
export const getConfigsSlice = (): any => readConsolidated()?.configs ?? null;
export const getDepsSlice = (): any => readConsolidated()?.deps ?? null;
export const FRONT_DEPS_PATH = join(GIT_BASE, "front", "front-deps.json");
export const FRONT_TOPOLOGY_PATH = join(GIT_BASE, "front", "front-topology.json");
export const BUILD_SCRIPT = join(SOLUTIONS_DIR, "build.sh");
export const SSH_CONFIG_PATH = join(HOME, ".ssh/config");
export const SOPS_AGE_KEY_FILE = join(HOME, ".config/sops/age/keys.txt");
export const AUTHELIA_TOKEN_PATH = join(HOME, ".config/authelia/tokens.json");
// C3 API endpoints — resolved from cloud-data at import time
// Lazy: read once, cache. Falls back to hardcoded if topology unavailable.
function resolveC3Api(): { mesh: string; public: string } {
  try {
    const topo = JSON.parse(readFileSync(resolveConfigPath(), "utf-8"));
    const c3Svc = topo.services?.["c3-infra-api"] ?? topo.services?.["c3-infra-mcp"];
    const c3Vm = c3Svc?.vm;
    const wgIp = c3Vm ? topo.vms?.[c3Vm]?.wg_ip : null;
    const port = c3Svc?.port;
    const domain = topo.owner?.domain ?? "diegonmarcos.com";
    return {
      mesh: wgIp && port ? `http://${wgIp}:${port}` : "http://10.0.0.6:8081",
      public: `https://api.${domain}/c3-api`,
    };
  } catch {
    return { mesh: "http://10.0.0.6:8081", public: "https://api.diegonmarcos.com/c3-api" };
  }
}
const _c3Api = resolveC3Api();
export const C3_API_MESH = _c3Api.mesh;
export const C3_API_PUBLIC = _c3Api.public;

export const FRONT_DIR = join(GIT_BASE, "front");
export const FRONT_BUILD_SCRIPT = join(FRONT_DIR, "build.sh");

// (CLOUD_DATA_DIR + CLOUD_DATA_REPO declared earlier in the file.)

export const REPOS: Record<string, string> = {
  "cloud-data": CLOUD_DATA_DIR,
  cloud: join(GIT_BASE, "cloud"),
  unix: join(GIT_BASE, "unix"),
  vault: join(GIT_BASE, "vault"),
  front: FRONT_DIR,
  tools: join(GIT_BASE, "tools"),
};

// ── Repo sync ────────────────────────────────────────────────────────
let _lastSync = 0;
const SYNC_TTL = 5 * 60 * 1000; // 5 minutes

/**
 * Sync repos to latest remote state.
 *
 * SERVER mode (Docker): `git fetch + reset --hard` — repos are disposable clones.
 * CLIENT mode (local):  no-op — the user's working copy is the source of truth.
 *                       Never run destructive git commands on working repos.
 */
/** Git SSH command — disable host key checking for non-interactive use */
const GIT_SSH = `GIT_SSH_COMMAND="ssh -i ${SSH_IDENTITY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"`;

export function syncRepos(force = false): void {
  if (process.env.REPO_SYNC === "off") return;
  if (IS_CLIENT) return; // Never touch the user's working repos

  const now = Date.now();
  if (!force && now - _lastSync < SYNC_TTL) return;
  _lastSync = now;

  for (const [name, dir] of Object.entries(REPOS)) {
    try {
      if (!existsSync(join(dir, ".git"))) {
        // Auto-clone missing repos (e.g. cloud-data on first run)
        const repoUrl = REPO_URLS[name];
        if (!repoUrl) continue;
        // Sparse checkout for large repos — only get build.json + config files
        execSync(`${GIT_SSH} git clone --depth 1 --filter=blob:none --sparse ${repoUrl} ${dir} && cd ${dir} && git sparse-checkout set a_solutions/*/build.json a_solutions/*/src/flake.nix config.json`, {
          timeout: 60000,
          stdio: "ignore",
        });
      } else {
        execSync(`${GIT_SSH} git fetch --all -q && git reset --hard origin/main -q`, {
          cwd: dir,
          timeout: 15000,
          stdio: "ignore",
        });
      }
    } catch {
      // Non-fatal — use stale data
    }
  }
}

/** Git remote URLs for auto-cloning in server mode */
const REPO_URLS: Record<string, string> = {
  "cloud-data": CLOUD_DATA_REPO,
  cloud: "git@github.com:diegonmarcos/cloud.git",
};
