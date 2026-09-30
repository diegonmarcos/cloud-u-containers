// Tester: the edge must withhold the fleet bearer from gitea, and gitea must
// project the public edge (not the caller's Host) in clone_url/html_url.
//
// Regression it guards (2026-09-30): the git.diegonmarcos.com gate passed a
// valid fleet bearer and Caddy then FORWARDED the Authorization header; gitea
// read the JWT as one of its own tokens and answered 401 — no bearer client
// could use the API or clone, even a public repo.
//
// Static on purpose: CI is off-mesh and holds no fleet bearer. The live proof
// (bearer -> 200 through the edge) is in the commit that introduced this.
import { readFileSync } from "node:fs";

const read = (p: string) => readFileSync(new URL(p, import.meta.url), "utf8");
let failed = 0;
const t = (name: string, ok: boolean) => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}`);
  if (!ok) failed++;
};

// 1. Both protected templates carry the hook in the BEARER branch only.
for (const tpl of ["23-protected.caddy.tpl", "24-protected-custom.caddy.tpl"]) {
  const s = read(`../../infra-sec_caddy/src/snippets/${tpl}`);
  const bearerBranch = s.slice(s.indexOf("handle @bearer"), s.indexOf("@AUTHELIA_BLOCK@"));
  t(`${tpl}: @BEARER_HEADER_UP@ exactly once`, s.split("@BEARER_HEADER_UP@").length === 2);
  t(`${tpl}: hook sits in the @bearer branch`, bearerBranch.includes("@BEARER_HEADER_UP@"));
}

// 2. Both builders substitute it (an unsubstituted placeholder is a Caddy parse error),
//    and the subdomain route builder feeds its own route options in.
const nix = read("../../infra-sec_caddy/src/caddyfile.nix");
t("caddyfile.nix substitutes @BEARER_HEADER_UP@ in both builders",
  (nix.match(/"@BEARER_HEADER_UP@"\s*=\s*bearerHeaderUp opts;/g) || []).length === 2);
t("caddyfile.nix emits header_up -Authorization on strip_authorization",
  /strip_authorization or false then "\\n\s+header_up -Authorization"/.test(nix));
t("mkSubdomainRoute shadows mkProtected with the route's options",
  /mkProtected\s+= mkProtectedOpt route;/.test(nix) && /mkProtectedCustom\s+= mkProtectedCustomOpt route;/.test(nix));

// 3. gitea declares the strip, and pins its public URL to ROOT_URL.
const build = JSON.parse(read("../build.json"));
t("gitea build.json proxy.primary.strip_authorization === true", build.proxy?.primary?.strip_authorization === true);
t('gitea compose.nix PUBLIC_URL_DETECTION = "never"',
  /GITEA__server__PUBLIC_URL_DETECTION\s*=\s*"never";/.test(read("compose.nix")));

if (failed) { console.error(`${failed} check(s) failed`); process.exit(1); }
