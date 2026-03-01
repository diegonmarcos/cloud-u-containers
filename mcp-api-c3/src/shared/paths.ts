import { homedir } from "os";
import { join } from "path";

export const HOME = homedir();
export const GIT_BASE = process.env.GIT_BASE ?? join(HOME, "git");
export const SOLUTIONS_DIR = join(GIT_BASE, "cloud/a_solutions");
export const CONFIG_PATH = process.env.CONFIG_JSON_PATH ?? join(SOLUTIONS_DIR, "..", "config.json");
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
