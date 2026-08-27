# GraphRAG Architecture & Continuous-Improvement Audit

> Design of the `cloud-cgc-pub-mcp` code/infra knowledge stack, and a **data-driven
> audit** of where it currently lies to itself. The machine-checkable source of truth
> is [`graphrag-audit.json`](./graphrag-audit.json) — this file is the human view.
> Every claim below has a re-runnable `probe` in that JSON.

## 1. Three subsystems behind one MCP

`cgc` is not one graph. It is **three independent stores** stitched under one server,
each with its own build pipeline, its own data, and its own tools:

| Subsystem | Tools | Store | Built from |
|-----------|-------|-------|-----------|
| **CodeGraph** | `codegraph_{overview,search,dependencies,impact_analysis,trace_call_path}` | in-memory, 5-min TTL | **image-baked** `./graphs/*.json` → `build-kg-graph_delta.json` (infra) + `code-signatures-<repo>.json` (code) |
| **kg-store** | `kgstore_query`, `kgstore_overview` | persistent **SurrealDB** `:8001` ns=infra db=production | a **separate ingest**: octocode's live per-repo mirror + infra topology |
| **octocode** | `octocode_{search,graphrag,index}` | LanceDB vectors + LLM GraphRAG | per-repo semantic index, reindexed **independently per repo** |

Engine: `src/code/tools/b-code-graph-context/{codegraph,kgstore,octocode}.ts`.

The critical, load-bearing fact: **CodeGraph and kg-store are built by different
pipelines, at different times, from different scans, using different repo names.**
They share no code-level edge tables. `codegraph_overview` describes *only* CodeGraph.

```
                        ┌──────────────── cgc-pub-mcp ────────────────┐
   code-signatures-*.json ─(baked)─▶ CodeGraph (in-mem)   symbol/defines/imports/code_depends_on
   build-kg-graph_delta.json ──────▶   ▲ overview counts THESE, and only these
                                        │
   octocode reindex ─(live)─▶ SurrealDB kg-store   file + sibling_module + parent_module + infra
                                        │           (NO symbol/defines/code_depends_on)
   per-repo vectors ────────▶ octocode GraphRAG   (new repo names: cloud-infra/cloud-unix/…)
```

## 2. The divergence, quantified

`overview` advertises **33,510 nodes / 37,908 edges**. Almost none of the *code* half
is reachable through `kgstore_query`:

| element | CodeGraph `overview` | SurrealDB `kgstore` |
|---|--:|--|
| symbol nodes | 29,660 | **0** — no table |
| file nodes | 2,905 | **3,843** |
| defines edges | 32,510 | **0** — no table |
| imports edges | 1,063 | **0** — table empty (imports = field on `file`) |
| code_depends_on | 3,959 | **0** — no table |
| sibling_module | *uncounted* | **44,354** |
| parent_module | *uncounted* | present |
| routes_to | 42 | 41 |

So `overview`'s edge total (37,908) is *smaller than a single kg-store table it
doesn't count* (`sibling_module` = 44,354), and *larger than everything kg-store can
actually answer about code* (≈0). The number is meaningless to anyone writing SurrealQL.

## 3. Flaw register

Full detail (probe, expected, observed, root cause, fix) in `graphrag-audit.json`.
Ranked by severity:

| ID | Sev | Flaw | Root cause | Cheapest fix |
|----|-----|------|-----------|--------------|
| INV-01 | 🔴 high | `overview` counts (symbol/defines/code_depends_on ≈65k) unreachable via kgstore | two builders, one banner | label overview rows by `queryable_via` |
| INV-02 | 🔴 high | **3 repo vocabularies** (cloud vs cloud-infra vs …) | named across the repo rename | canonical names + alias map at ingest |
| INV-03 | 🔴 high | `file.repo` refs 6 repos, only 3 `repo` nodes (front/front-data/tools dangle) | delta builder emits 3 | emit a repo node per distinct file.repo |
| INV-05 | 🔴 high | tool's **own example queries return 0 rows** (`repo='cloud-infra'`) | doc uses new names, data uses old | fix example strings (or fix INV-02) |
| INV-04 | 🟡 med | `belongs_to_repo` collapses all 62 modules → `repo:cloud` | only infra modules modeled | document as infra-only until code modules land |
| INV-06 | 🟡 med | `kgstore_overview` lists phantom tables (`connected_to`/`documentation`/`log`), hides real (`parent_module`/`imports`) | hardcoded table list drifted | derive list from `INFO FOR DB` |
| INV-07 | 🟡 med | file inventory 2,905 vs 3,843 (per-repo wildly off) | baked scan vs live scan | share one enumeration, pin to one commit |
| INV-09 | 🟡 med | `code_depends_on` is really file→**package**, not file→file | misnaming | rename `depends_on_package` |
| INV-10 | 🟡 med | missing table → silent `count:0`, not an error | SurrealDB semantics | validate FROM targets vs `INFO FOR DB` |
| INV-11 | 🟡 med | octocode index freshness **uneven** (cloud-infra fresh, cloud-unix stale) | per-repo reindex not fired on rename | reindex-on-push for all repos |
| INV-08 | 🟢 low | `routes_to` 42 vs 41 | baked delta one gen behind | rebuild delta in the ingest job |
| INV-12 | 🟢 low | version split: package.json 5.0.0 vs code 7.0.0 | hand-edited | import version from package.json |
| INV-13 | ⚪ open | `octocode_graphrag search` dumped ~4MB; graph ops unvalidated | unknown | cap result size, then validate |

**What works** (keep these covered — see `passing_controls`): the read-only mutation
guard (load-bearing — SurrealDB tables are `PERMISSIONS NONE`), cross-layer
`impact_analysis`, directed-path honesty in `trace_call_path`, and the `routes_to`
catalog matching the live hub.

## 4. The two root causes worth fixing first

Everything above collapses into two engine problems:

1. **One vocabulary.** (INV-02/03/05) Pick the canonical repo names
   (`cloud-infra`, `cloud-unix`, …), use them in code-signatures filenames, the
   delta repo-node builder, and octocode — with an alias map so old baked snapshots
   still resolve. This alone fixes the dangling repos and the broken tool examples.

2. **One build, one truth.** (INV-01/07/08) CodeGraph reads image-baked JSON while
   kg-store reads a live mirror. Either ingest CodeGraph's synthesized `symbol`/
   `defines` into SurrealDB, or stop `overview` from counting what only lives
   in-memory — and pin both scans to the same commit in one job.

## 5. Continuous-improvement loop

`graphrag-audit.json` is a **regression gate**, not a snapshot:

1. Run every `invariants[].probe` (a small Workflow iterating the array does this).
2. Write results into `observed`; set `status` PASS / FAIL / OPEN.
3. An invariant is **DONE** when `status = PASS` and `fix` is empty.
4. A PASS that flips to FAIL is a regression — the probe is the reproduction.

New probes are added as data (a JSON object), never as prose here. This document is
regenerated from the JSON, so the JSON is the only thing to edit.
