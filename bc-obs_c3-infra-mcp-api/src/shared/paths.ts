import { existsSync } from "fs";
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
export const CONFIG_PATH = process.env.CONFIG_JSON_PATH
  ?? (existsSync(join(SOLUTIONS_DIR, "..", "cloud-data-topology.json"))
    ? join(SOLUTIONS_DIR, "..", "cloud-data-topology.json")
    : join(SOLUTIONS_DIR, "..", "config.json"));
export const CONFIGS_PATH = join(SOLUTIONS_DIR, "..", "cloud-data-configs.json");
export const DEPS_PATH = join(SOLUTIONS_DIR, "..", "cloud-data-deps.json");
export const FRONT_DEPS_PATH = join(GIT_BASE, "front", "front-deps.json");
export const BUILD_SCRIPT = join(SOLUTIONS_DIR, "build.sh");
export const SSH_CONFIG_PATH = join(HOME, ".ssh/config");
export const SOPS_AGE_KEY_FILE = join(GIT_BASE, "vault/A0_keys/providers/system/oauth/age_keys.txt");
export const AUTHELIA_TOKEN_PATH = join(GIT_BASE, "vault/A0_keys/providers/authelia/oauth/authelia_tokens.json");
export const CRAWLEE_API_TOKEN_PATH = process.env.CRAWLEE_API_TOKEN
  ? ""  // token provided via env, no file needed
  : join(GIT_BASE, "vault/A0_keys/providers/crawlee/api_token");

// C3 API endpoints - mesh primary (oci-apps), public fallback with auth
export const C3_API_MESH = "http://10.0.0.6:8081";
export const C3_API_PUBLIC = "https://api.diegonmarcos.com/c3-api";

export const FRONT_DIR = join(GIT_BASE, "front");
export const FRONT_BUILD_SCRIPT = join(FRONT_DIR, "build.sh");

export const REPOS: Record<string, string> = {
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
export function syncRepos(force = false): void {
  if (IS_CLIENT) return; // Never touch the user's working repos

  const now = Date.now();
  if (!force && now - _lastSync < SYNC_TTL) return;
  _lastSync = now;

  for (const [name, dir] of Object.entries(REPOS)) {
    if (!existsSync(join(dir, ".git"))) continue;
    try {
      execSync("git fetch --all -q && git reset --hard origin/main -q", {
        cwd: dir,
        timeout: 15000,
        stdio: "ignore",
      });
    } catch {
      // Non-fatal — use stale data
    }
  }
}
