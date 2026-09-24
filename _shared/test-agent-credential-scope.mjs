// Tester: #359 — only services that ARE agents hold the push credential.
//
// The engine handed the shared tree and every sops key to EVERY service in a
// compose project. my-ai-api's project also runs cloud-agi-bots, a Telegram
// gateway that only makes HTTP calls, so it held GH_TOKEN (a classic PAT with
// admin:org, delete_repo, admin:enterprise) in its env, in /run/secrets and in
// /run/secrets.json, with a writable tree and a push helper beside it.
//
// _shared/agent-credential.nix decides who is an agent, from build.json
// agent.services. It is pure builtins, so it is EVALUATED here against each
// holder's real rendered compose project. The engine's use of it needs
// nixpkgs to evaluate, so that part is a parse + source check (section E).
//
// Holders are DERIVED: every service dir whose src/secrets.yaml declares the
// credential key, where the key name is read from agent-credential.nix itself.
//
// Usage: node _shared/test-agent-credential-scope.mjs   (cwd anywhere)
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SHARED = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SHARED, "..");

let pass = 0, fail = 0;
const check = (n, c, d = "") => c
  ? (pass++, console.log(`PASS ${n}`))
  : (fail++, console.error(`FAIL ${n}${d ? ` — ${d}` : ""}`));

let nixOk = true;
try { execFileSync("nix-instantiate", ["--version"], { stdio: "pipe" }); } catch { nixOk = false; }
check("N0 nix-instantiate is available (this tester EVALUATES, it does not grep)", nixOk,
  "install nix in the job — a missing evaluator must fail, not skip");
if (!nixOk) { console.error("NOT GREEN"); process.exit(1); }

const nixEval = (expr) => JSON.parse(execFileSync(
  "nix-instantiate", ["--eval", "--strict", "--json", "--expr", expr],
  { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
const nixThrows = (expr) =>
  !nixEval(`(builtins.tryEval (builtins.deepSeq (${expr}) true)).success`);

// agentSpec override: null = the service's real build.json agent block.
const bjExpr = (svc) => `(builtins.fromJSON (builtins.readFile ./${svc}/build.json))`;
const credExpr = (svc, agentOverride = null) =>
  `(import ./_shared/agent-credential.nix { agentSpec = ${
    agentOverride ?? `(${bjExpr(svc)}.agent or {})`}; })`;
// container = {}: the build-<name>.json symlinks point into cloud-infra, which
// this checkout does not have; every holder's compose falls back without it.
const composeExpr = (svc) =>
  `(import ./${svc}/src/compose.nix { buildJson = ${bjExpr(svc)}; container = {}; })`;

// ── A. who holds the credential — derived, never listed here ────────────────
const VAR = nixEval(`(import ./_shared/agent-credential.nix { agentSpec = {}; }).var`);
const holders = readdirSync(ROOT).filter((d) => {
  const f = join(ROOT, d, "src", "secrets.yaml");
  return existsSync(f) && new RegExp(`^${VAR}:`, "m").test(readFileSync(f, "utf8"));
}).sort();
check(`A1 at least one container's sops declares ${VAR} (else the key name drifted)`,
  holders.length >= 1, `holders: ${holders.join(",")}`);

let withheldTotal = 0;
for (const svc of holders) {
  const names = nixEval(`builtins.attrNames ${composeExpr(svc)}.services`);
  const declared = JSON.parse(readFileSync(join(ROOT, svc, "build.json"), "utf8")).agent?.services ?? null;

  // A second service in an agent project must be classified on purpose, or it
  // silently inherits the credential — which is exactly how the bots got it.
  check(`B1 ${svc}: ${names.length} service(s); >1 requires agent.services`,
    names.length === 1 || Array.isArray(declared),
    `services ${JSON.stringify(names)} but agent.services is not declared`);
  check(`B2 ${svc}: agent.services names only real services (engine would throw)`,
    !nixThrows(`${credExpr(svc)}.checkNames (builtins.fromJSON ''${JSON.stringify(names)}'')`));

  const agents = names.filter((n) => nixEval(`${credExpr(svc)}.isAgent "${n}"`));
  const others = names.filter((n) => !agents.includes(n));
  check(`B3 ${svc}: at least one service is still an agent (nobody lost the tree)`,
    agents.length >= 1, `services ${JSON.stringify(names)}`);

  for (const n of others) {
    withheldTotal++;
    const env = nixEval(`(${credExpr(svc)}.withhold ${composeExpr(svc)}.services."${n}").environment`);
    const blanked = Array.isArray(env) ? env.includes(`${VAR}=`) : env[VAR] === "";
    check(`C1 ${svc}/${n}: rendered environment blanks ${VAR} over the env_file`, blanked,
      JSON.stringify(env[VAR]));
    // Mutation, rendered: drop the declaration and the SAME service must be an
    // agent again. Proves the verdict follows build.json, not a constant.
    check(`C2 ${svc}/${n}: without agent.services it would hold ${VAR} (verdict follows the declaration)`,
      nixEval(`${credExpr(svc, "{}")}.isAgent "${n}"`) === true);
  }
}
check("C0 at least one service fleet-wide is withheld the credential (C1/C2 not vacuous)",
  withheldTotal >= 1, `withheld=${withheldTotal}`);

// ── D. the function's own edges ─────────────────────────────────────────────
check("D1 a misspelt agent.services name fails the build",
  nixThrows(`(import ./_shared/agent-credential.nix { agentSpec = { services = [ "no-such-svc" ]; }; }).checkNames [ "a" ]`));
check("D2 list-form environment is blanked too",
  nixEval(`(import ./_shared/agent-credential.nix { agentSpec = {}; }).withhold { environment = [ "X=1" ]; }`)
    .environment.includes(`${VAR}=`));

// ── E. the engine uses it (parse + source; full eval needs nixpkgs) ─────────
let parsed = true;
try { execFileSync("nix-instantiate", ["--parse", join(SHARED, "engine.nix")], { stdio: "pipe" }); }
catch { parsed = false; }
check("E1 engine.nix parses", parsed);
const engine = readFileSync(join(SHARED, "engine.nix"), "utf8")
  .split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
check("E2 engine imports agent-credential.nix with the build.json agent block",
  /import\s+\.\/agent-credential\.nix\s*\{\s*inherit\s+agentSpec;\s*\}/.test(engine));
check("E3 agents get the tree + all secrets; others get withhold + env_file only",
  /if\s+agentCredential\.isAgent\s+name\s+then\s+mergeSecretsInto\s*\(mergeGitTreeInto\s*\(mergeSvc svc\)\)\s+else\s+agentCredential\.withhold\s*\(mergeSecretsEnvOnly\s*\(mergeSvc svc\)\)/.test(engine));
const envOnly = /mergeSecretsEnvOnly\s*=\s*svc:([\s\S]*?);\n\n/.exec(engine)?.[1] ?? "";
check("E4 mergeSecretsEnvOnly mounts no /run/secrets volumes", envOnly !== "" && !/secretsVolumes/.test(envOnly),
  envOnly || "mergeSecretsEnvOnly not found");
check("E5 checkNames is forced in applyDefaults (a lazy throw is decoration)",
  /builtins\.seq\s*\(agentCredential\.checkNames/.test(engine));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
