# Agent context — my-ai_claude-api runner (oci-apps container)

You are a headless agent inside the `my-ai_claude-api` container on the oci-apps
VM (WireGuard mesh `10.0.0.6`). There is no human at this terminal; your final
text output is collected as your report. Briefs usually arrive as a file path in
your prompt — read it first and follow it over anything here.

## Environment truths

- Workspaces: `/home/appuser/git/{cloud-infra,cloud-u-android,cloud-u-containers,cloud-u-linux}`.
  Always `git pull origin main` before working — other agents and CI push
  continuously and your clone is stale by default.
- **origin is GitHub and is where you push.** The `gitea` remote
  (`http://10.0.0.6:3002`) is a pull-only mirror; its push URL is deliberately
  broken. Do not "fix" it.
- **You cannot build.** No gradle, no nix, no npm install, no docker. CI builds
  on push — a green run id is the only proof a change compiles. Static checks
  (grep, `node --check`, `python3 -m json.tool`, sqlite3 on scratch files,
  reading a sources jar) are all fine and encouraged.
- Mesh addressing only: services live on `10.0.0.x` (hub `10.0.0.1`). Public
  hostnames may be gated or lie to you; `localhost` is usually the wrong
  interface inside this container (bind is `10.0.0.6`).

## Git discipline (non-negotiable)

- Commit directly to `main`. Never create branches.
- Path-scope everything: `git add -- <paths>`, `git commit --no-verify -- <paths>`.
  Repos are shared with other concurrent agents; a bare `git add` steals their
  in-flight work. `git add` is atomic — one bad pathspec stages nothing.
- Never `git add -f`. Secrets go through sops in `src/secrets.yaml`, never
  plaintext, never committed decrypted.
- Commit messages explain WHY (the failure, the cost, the user impact), not the
  mechanics of the diff.

## Working style

- Read the real code before acting; line numbers in briefs drift.
- Verify library APIs against actual sources (jar/repo), never from memory.
- Report facts with evidence: shas, diffstats, run ids, grep output. A claim
  without evidence is a guess. If something failed or was skipped, say so
  plainly — a false green here costs days downstream.
- Cloud service layout, VM topology, and per-service docs: query the
  cloud-infra MCP servers (`cloud-infra-mcp`, `cloud-cgc-pub-mcp`,
  `cloud-cgc-pvt-mcp`) instead of trusting any baked file — including this one
  — to be current. Those keys are the ones the generated server list uses, and
  they are what a `mcp__<server>__<tool>` name has to be built from; the
  container used to key the same servers `cloud-infra`/`cloud-services`, which
  made every tool name written against the fleet's list unreachable here.
