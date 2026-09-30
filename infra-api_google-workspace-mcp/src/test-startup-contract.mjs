// google-workspace-mcp startup contract. Two outage classes, one assertion each:
//  1. a plain `uv run` re-syncs the venv at container start (default groups incl.
//     dev -> downloads ruff, builds the project): startup depends on PyPI being up.
//     Deps are baked by `uv sync` at image build; the entrypoint must not re-resolve.
//  2. safe_print muted everything when stderr was not a TTY, so a fatal
//     "Port ... already in use" + sys.exit(1) left a bare exit 1 in docker logs.
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const bj = JSON.parse(readFileSync(new URL("../build.json", import.meta.url)));
const ep = bj.docker.native_build.entrypoint.split(/\s+/);
let fail = 0;
const check = (ok, msg) => { console.log(`${ok ? "PASS" : "FAIL"} ${msg}`); if (!ok) fail++; };

check(ep[0] !== "uv" || (ep[1] === "run" && ep.includes("--no-sync")),
  `entrypoint does not re-sync deps at start: ${ep.join(" ")}`);

// Run the real safe_print (extracted from main.py) with stderr piped = non-TTY.
const src = readFileSync(new URL("./code/main.py", import.meta.url), "utf8");
const fn = src.match(/^def safe_print\(text\):\n(?:(?: {4}.*)?\n)+/m);
check(!!fn, "safe_print found in main.py");
if (fn) {
  const py = `import sys, logging\n_CLI_MODE = False\nlogger = logging.getLogger("t")\n${fn[0]}\nsafe_print("FATAL-CAUSE-MARKER")\n`;
  const r = spawnSync("python3", ["-c", py], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  check(r.status === 0 && r.stderr.includes("FATAL-CAUSE-MARKER"),
    `safe_print reaches non-TTY stderr (status=${r.status}, stderr=${JSON.stringify((r.stderr || "").slice(0, 200))})`);
}
process.exit(fail ? 1 : 0);
