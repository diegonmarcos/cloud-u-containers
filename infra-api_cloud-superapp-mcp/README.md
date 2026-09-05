# cloud-superapp-mcp

One MCP server and one HTTP API over the Android constellation's on-device
debug API. Reached from `cloud-u-android/aa_cloud-superapp-mcp` — that path is
a symlink to this directory, which lives in the `a_solutions` submodule whose
source clone is `~/git/cloud-u-containers`. **Edit it there.**

The tree lives under `src/code/` — the fleet convention is that a service's
app tree sits at `src/<app_dir>/`, and `app_dir` here is `code`:

```
src/code/lib-api/            the route contract every app is guaranteed to serve
src/code/lib-mcp/            transport, the default tools, the app-module registry
src/code/mcps-apps/<app>/    one folder per constellation app (18 today)
src/code/cloud-superapp-mcp/ the MCP face  — stdio or streamable HTTP (`--http`)
src/code/cloud-superapp-api/ the HTTP face — same modules, loopback only
```

## The privileged plane (Shizuku-class, through one door)

The six unprivileged tools see one app each. Seven more wrap the superapp's
`adb/exec` (uid-2000 shell via Shizuku / embedded adb / the bootstrapped
shell-domain server): `superapp_shell` (verb-allowlisted; `dangerously_raw`
for the rest), `superapp_logcat_full` (whole system, or any app by uid — the
view Android hides from everyone else), `superapp_grant` (incl. development
permissions like READ_LOGS), `superapp_force_stop`, `superapp_input`,
`superapp_screencap`, `superapp_adb_status` (channel health + the
once-per-boot bootstrap command). The channel must be re-armed after a
reboot — `superapp_adb_status` prints the command; wiring it into the phone's
boot automation is the standing TODO that would make this permanent.

## Where the API actually lives

Not here. `ab_cloud-libs-shared/libs/devtools/AppDebugServer.kt` is the API:
every app that links `libs:core` binds a loopback port (38090-38139; 38080 is
the older DevControlServer in SuperApp and cloud-nav) and serves the contract
— `system/ping`, `system/info`, `diagnostics/logcat`, `diagnostics/crashes`,
`fleet/peers`, `fleet/wake` — plus anything it registers through
`AppDebugServer.route("<group>") { op, query -> ... }`, self-catalogued into
`/api/docs`.

`src/code/lib-api/src/contract.ts` is a **mirror** of that, so the two faces here agree
on what an app must answer without either hardcoding it. A mirror can drift;
`superapp_docs` asks the device and is always the truth. Prefer it whenever
the two could disagree.

Those sockets bind 127.0.0.1, so nothing off-device reaches them. Both faces
go in the way a human does: `ssh phone`, curl from inside. One remote script
per call, because a port sweep is 60 probes and 60 ssh handshakes is a minute.

## One process, not twenty

An MCP tool is `{name, schema, call}` — it needs no process of its own, so
twenty apps do not need twenty servers, twenty stdio entries in `.mcp.json`,
or twenty ssh transports racing for one phone. And generating the tool list
from the devices at connect time would mean a phone that is asleep yields a
server with **zero tools**, which is exactly when you reach for it.

So the tool set is fixed at six and takes `app` as an argument.
`superapp_call` is the escape hatch that keeps this from needing to know about
a new app route; `superapp_docs` is how it stays discoverable.

## What a module under `src/code/mcps-apps/` is for

A description of an app, not a server. It earns its place three ways:

- an alias, so a human says `cloud-mail` where the device knows only
  `com.diegonmarcos.comms.mail` — resolved from the module list, with no round
  trip to a phone that may be asleep;
- a place to document routes the app adds via `AppDebugServer.route()`, so
  they are discoverable when the phone is unreachable — which is when you are
  guessing;
- an optional `tools` hook for ergonomics `superapp_call` genuinely cannot
  express. **Nothing uses it today, on purpose.** A tool per app per route is
  how a six-tool server becomes a hundred-tool server no model can choose
  within.

Adding an app is one folder: `loadModules()` reads the directory, so there is
no barrel file to forget.

## Adding a route to an app

Two edits, in one change, in this order:

1. the app's Kotlin — `AppDebugServer.route("news", listOf(Op(...))) { ... }`;
2. `src/code/mcps-apps/<app>/index.ts` — list the same ops under `routes`.

It is callable via `superapp_call` the moment the APK lands, whether or not
step 2 happened. Step 2 is what makes it findable offline. Doing 2 without 1
produces a catalog that lies, which is worse than an empty one because it is
believed.

## Wiring

`.mcp.json` is generated from `a_solutions/*/build.json` `.mcp` blocks by
`1_cloud-configs/src/derive/derive-mcp-json.ts`. That deriver currently
**skips stdio servers** ("the binary path is machine-specific"), so this one
is not in the file yet. Emitting them needs a `command`/`args` form using the
same `${VAR:-default}` expansion the file already uses for `headersHelper`.

Run it by hand meanwhile:

```
cd src/code/cloud-superapp-mcp && npm start        # stdio MCP
cd src/code/cloud-superapp-api && npm start        # HTTP face, 127.0.0.1:38150
```

`SUPERAPP_FLEET_TOKEN` (SuperApp -> Configs -> About) unlocks the data routes;
without it discovery still works and everything else answers 401.
`SUPERAPP_HOSTS` overrides the ssh host list (`phone,phone-v6,phone-pub`, or
`local` on the device itself).
