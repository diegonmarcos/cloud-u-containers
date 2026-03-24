// gen-deps.ts — Generate cloud-data-deps.json + front-deps.json from package.json files
//
// Sources:
//   cloud/a_solutions/*/src/package.json    → per-service node dependencies
//   cloud/a_solutions/*/build.json          → service metadata (name, category)
//   cloud/config.json .deps.node             → repo-level node requirements
//   front/**/package.json                   → per-project node dependencies
//   front/**/build.json                     → project metadata
//
// Outputs (written directly to data submodules, symlinked from repo roots):
//   cloud-data/cloud-data-deps.json   → consolidated cloud deps grouped by language
//   front-data/front-deps.json   → consolidated front deps grouped by language
//
// Consumed by:
//   Home-manager           → reads node section to populate ~/.node_modules/
//   C3 API GET /deps       → serves live

import { readFileSync, writeFileSync, existsSync, readdirSync } from "fs";
import { join, dirname, resolve } from "path";
import { execSync } from "child_process";
import { homedir } from "os";
import { fileURLToPath } from "url";

// --- Paths ----------------------------------------------------------------

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const CLOUD_ROOT_DEFAULT = resolve(SCRIPT_DIR, "../../../..");
const GIT_BASE = process.env.GIT_BASE ?? dirname(CLOUD_ROOT_DEFAULT);
const CLOUD_ROOT = process.env.GIT_BASE ? join(GIT_BASE, "cloud") : CLOUD_ROOT_DEFAULT;
const FRONT_ROOT = join(GIT_BASE, "front");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const CONFIG_JSON = join(CLOUD_ROOT, "config.json");

const CLOUD_DATA_DIR = join(CLOUD_ROOT, "cloud-data");
const FRONT_DATA_DIR = join(FRONT_ROOT, "front-data");
const CLOUD_OUTPUT = join(CLOUD_DATA_DIR, "cloud-data-deps.json");
const FRONT_OUTPUT = join(FRONT_DATA_DIR, "front-deps.json");

// --- Types ----------------------------------------------------------------

interface PackageDeps {
  dependencies: Record<string, string>;
  devDependencies: Record<string, string>;
}

interface ServiceDeps {
  service: string;
  folder: string;
  category: string;
  dependencies: Record<string, string>;
  devDependencies: Record<string, string>;
}

interface RepoDeps {
  _meta: {
    generated_by: string;
    api_route: string;
    generated_at: string;
    total_services: number;
    total_packages: number;
  };
  node: {
    merged: PackageDeps;
    per_service: ServiceDeps[];
  };
}

// --- Helpers ---------------------------------------------------------------

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf-8"));
}

function takeHigher(existing: string | undefined, candidate: string): string {
  if (!existing) return candidate;
  return candidate > existing ? candidate : existing;
}

function sort(obj: Record<string, string>) {
  return Object.fromEntries(Object.entries(obj).sort(([a], [b]) => a.localeCompare(b)));
}

function buildOutput(
  generatedBy: string,
  apiRoute: string,
  mergedDeps: Record<string, string>,
  mergedDevDeps: Record<string, string>,
  perService: ServiceDeps[],
): RepoDeps {
  const totalPackages = Object.keys(mergedDeps).length + Object.keys(mergedDevDeps).length;
  return {
    _meta: {
      generated_by: generatedBy,
      api_route: apiRoute,
      generated_at: new Date().toISOString(),
      total_services: perService.length,
      total_packages: totalPackages,
    },
    node: {
      merged: {
        dependencies: sort(mergedDeps),
        devDependencies: sort(mergedDevDeps),
      },
      per_service: perService.sort((a, b) => a.folder.localeCompare(b.folder)),
    },
  };
}

// --- Cloud deps -----------------------------------------------------------

function scanCloud(): RepoDeps {
  console.log("gen-deps [cloud]: scanning a_solutions/*/src/package.json...");

  const mergedDeps: Record<string, string> = {};
  const mergedDevDeps: Record<string, string> = {};
  const perService: ServiceDeps[] = [];

  const folders = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  for (const folder of folders) {
    const pkgPath = join(SOLUTIONS_DIR, folder, "src", "package.json");
    if (!existsSync(pkgPath)) continue;

    const buildJsonPath = join(SOLUTIONS_DIR, folder, "build.json");
    let category = "unknown";
    let serviceName = folder;
    if (existsSync(buildJsonPath)) {
      try {
        const bj = readJson(buildJsonPath) as { name?: string; category?: string };
        serviceName = bj.name ?? folder;
        category = bj.category ?? "unknown";
      } catch { /* use defaults */ }
    }

    try {
      const pkg = readJson(pkgPath) as { dependencies?: Record<string, string>; devDependencies?: Record<string, string> };
      const deps = pkg.dependencies ?? {};
      const devDeps = pkg.devDependencies ?? {};

      for (const [k, v] of Object.entries(deps)) {
        mergedDeps[k] = takeHigher(mergedDeps[k], v);
      }
      for (const [k, v] of Object.entries(devDeps)) {
        mergedDevDeps[k] = takeHigher(mergedDevDeps[k], v);
      }

      perService.push({ service: serviceName, folder, category, dependencies: deps, devDependencies: devDeps });
      console.log(`  ${folder}: ${Object.keys(deps).length + Object.keys(devDeps).length} packages`);
    } catch (e) {
      console.warn(`  WARN: failed to parse ${pkgPath}: ${e}`);
    }
  }

  // Include repo-level config.json deps.node requirements
  if (existsSync(CONFIG_JSON)) {
    try {
      const config = readJson(CONFIG_JSON) as { deps?: { node?: { required?: string[] } } };
      const required = config.deps?.node?.required ?? [];
      for (const pkg of required) {
        if (!mergedDeps[pkg] && !mergedDevDeps[pkg]) {
          mergedDeps[pkg] = "latest";
        }
      }
      if (required.length > 0) {
        console.log(`  config.json: ${required.length} engine packages`);
      }
    } catch { /* skip */ }
  }

  return buildOutput(
    "c3-infra-mcp-api/src/engines/gen-deps.ts",
    "GET /c3-api/cloud-data/deps",
    mergedDeps,
    mergedDevDeps,
    perService,
  );
}

// --- Front deps -----------------------------------------------------------

function scanFront(): RepoDeps | null {
  if (!existsSync(FRONT_ROOT)) {
    console.log("gen-deps [front]: SKIP (front/ repo not found)");
    return null;
  }

  console.log("gen-deps [front]: scanning project package.json files...");

  const mergedDeps: Record<string, string> = {};
  const mergedDevDeps: Record<string, string> = {};
  const perService: ServiceDeps[] = [];

  // Find all build.json files (same pattern as front/build.sh _generate_package_json)
  let buildJsonPaths: string[];
  try {
    const raw = execSync(
      'find . -maxdepth 3 -name build.json -not -path ./build.json -not -path "./z_Archive/*" -not -path "./front-data/*"',
      { cwd: FRONT_ROOT, timeout: 10_000 },
    ).toString().trim();
    buildJsonPaths = raw ? raw.split("\n").filter(Boolean) : [];
  } catch {
    console.warn("  WARN: find failed");
    return null;
  }

  for (const bjsonRel of buildJsonPaths) {
    const dir = join(FRONT_ROOT, bjsonRel.replace(/\/build\.json$/, ""));
    const pkgPath = join(dir, "package.json");
    if (!existsSync(pkgPath)) continue;

    let category = "unknown";
    let serviceName = dir.split("/").pop() ?? "unknown";
    try {
      const bj = readJson(join(FRONT_ROOT, bjsonRel)) as { name?: string; category?: string };
      serviceName = bj.name ?? serviceName;
      category = bj.category ?? "unknown";
    } catch { /* use defaults */ }

    try {
      const pkg = readJson(pkgPath) as { dependencies?: Record<string, string>; devDependencies?: Record<string, string> };
      const deps = pkg.dependencies ?? {};
      const devDeps = pkg.devDependencies ?? {};

      for (const [k, v] of Object.entries(deps)) {
        mergedDeps[k] = takeHigher(mergedDeps[k], v);
      }
      for (const [k, v] of Object.entries(devDeps)) {
        mergedDevDeps[k] = takeHigher(mergedDevDeps[k], v);
      }

      const folder = bjsonRel.replace(/^\.\//, "").replace(/\/build\.json$/, "");
      perService.push({ service: serviceName, folder, category, dependencies: deps, devDependencies: devDeps });
      console.log(`  ${folder}: ${Object.keys(deps).length + Object.keys(devDeps).length} packages`);
    } catch (e) {
      console.warn(`  WARN: failed to parse ${pkgPath}: ${e}`);
    }
  }

  return buildOutput(
    "c3-infra-mcp-api/src/engines/gen-deps.ts",
    "GET /c3-api/cloud-data/deps/front",
    mergedDeps,
    mergedDevDeps,
    perService,
  );
}

// --- Main -----------------------------------------------------------------

function main() {
  // Cloud deps
  const cloudDeps = scanCloud();
  writeFileSync(CLOUD_OUTPUT, JSON.stringify(cloudDeps, null, 2) + "\n");
  console.log(`\ngen-deps [cloud]: written cloud-data-deps.json (${cloudDeps._meta.total_services} services, ${cloudDeps._meta.total_packages} packages)`);

  // Front deps
  const frontDeps = scanFront();
  if (frontDeps) {
    writeFileSync(FRONT_OUTPUT, JSON.stringify(frontDeps, null, 2) + "\n");
    console.log(`gen-deps [front]: written front-deps.json (${frontDeps._meta.total_services} projects, ${frontDeps._meta.total_packages} packages)`);
  }

  console.log("\ngen-deps: done.");
}

main();
