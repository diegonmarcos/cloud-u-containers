import { homedir } from "os";
import { join } from "path";

export const HOME = homedir();
export const GIT_BASE = join(HOME, "git");
export const CONTAINER_NIX_DIR = join(GIT_BASE, "cloud/a_solutions/container-nix");
export const CONFIG_PATH = join(CONTAINER_NIX_DIR, "config.json");
export const BUILD_SCRIPT = join(CONTAINER_NIX_DIR, "build.sh");
export const SSH_CONFIG_PATH = join(HOME, ".ssh/config");
export const SOPS_AGE_KEY_FILE = join(GIT_BASE, "vault/A0_keys/providers/system/oauth/age_keys.txt");
export const AUTHELIA_TOKEN_PATH = join(GIT_BASE, "vault/A0_keys/providers/authelia/oauth/authelia_tokens.json");

// Rust API endpoints - mesh primary, public fallback with auth
export const RUST_API_MESH = "http://10.0.0.1:8080";
export const RUST_API_PUBLIC = "https://api.diegonmarcos.com:8080";

export const FRONT_DIR = join(GIT_BASE, "front");
export const FRONT_BUILD_SCRIPT = join(FRONT_DIR, "build.sh");

export const REPOS: Record<string, string> = {
  cloud: join(GIT_BASE, "cloud/a_solutions/container-nix"),
  unix: join(GIT_BASE, "cloud/a_solutions/home-nix"),
  vault: join(GIT_BASE, "vault"),
  front: FRONT_DIR,
  tools: join(GIT_BASE, "tools"),
};
