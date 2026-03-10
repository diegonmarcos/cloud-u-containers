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

// SSH identity key — Android uses ~/.ssh/id_rsa (symlinked from vault)
// Desktop uses vault path directly (GIT_BASE may point to Mounts/Git)
export const SSH_IDENTITY = IS_ANDROID
  ? join(HOME, ".ssh/id_rsa")
  : join(GIT_BASE, "vault/A0_keys/ssh/id_rsa");
export const SOLUTIONS_DIR = join(GIT_BASE, "cloud/a_solutions");
export const CONFIG_PATH = process.env.CONFIG_JSON_PATH
  ?? (existsSync(join(SOLUTIONS_DIR, "..", "cloud-topology.json"))
    ? join(SOLUTIONS_DIR, "..", "cloud-topology.json")
    : join(SOLUTIONS_DIR, "..", "config.json"));
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

// ── Repo sync: git pull all repos (public HTTPS, read-only) ──────────
let _lastSync = 0;
const SYNC_TTL = 5 * 60 * 1000; // 5 minutes

/** Pull all cloned repos if TTL expired. Safe to call frequently. */
export function syncRepos(force = false): void {
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
