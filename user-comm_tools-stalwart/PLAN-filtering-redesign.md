# Mail filtering / tagging / copy system — design

Status: proposed. Written 2026-08-23.

## 0. What is already right — do not rebuild this

The routing and tagging half of this system is genuinely well-designed, and the
redesign below is *extension of an existing good pattern*, not replacement.

```
mail-rules-general.json      (universal, canonical)
mail-rules-profile-<id>.json (per-profile overlay)
          │  loadAndMerge
          ▼
_shared/lib/mail-rules.nix   (the one compiler)
          │
    ┌─────┼─────────────┬──────────────────┐
    ▼     ▼             ▼                  ▼
 toSieve  toMaddyJson   toLegacyJson     golden tests
(stalwart)  (maddy)     (jmap-sorter)
```

Specifically worth preserving:

- **One canonical source, one compiler, N engine artifacts.** Rules are written
  once and lowered per engine.
- **Named predicates.** `predicates` is a reusable atom table; rules reference
  atoms by name, with `any_of` / `all_of` / `not` combinators.
- **A degradation model.** `engines.<engine> ∈ full | route_only | tag_only | drop`
  encodes *deliberately* that maddy owns routing and Stalwart must not duplicate
  it. This is real design, and there is a bug-history comment in the compiler
  recording what happened the one time it was got wrong.
- **Stable slugs for routing folders.** `folders` is `slug → display name`
  (`admin`, `logistics`, `others`, …), and `routing_default: "others"` refers to
  a slug, not a string.
- **Golden tests** over the compiled sieve and maddy JSON.

Every defect below is a place where **the filter views (`A*`–`D*`) were left out
of this model.** The views are the one un-migrated corner; the compiler itself
names their artifact `toLegacyJson`.

---

## 1. Defects

### D1 — Views are the only thing that is never compiled

`toLegacyJson` passes `merged.filters` through **verbatim** (mail-rules.nix:405).
Routing and tags get predicate resolution, degradation, priority ordering,
bucket grouping and golden tests. Views get none of it. They are interpreted at
runtime by hand-written Python in `jmap-sorter.py`:

```python
if ptype == "size_min":   return size >= predicate["bytes"]
if ptype == "size_max":   return size <  predicate["bytes"]
if ptype == "size_range": return predicate["min"] <= size <= predicate["max"]
```

This is a **second, parallel predicate language** (`size_min`, `size_max`,
`size_range`, `newer_than_hours`, `unread`, `has_attachment`, `attach_type`),
disjoint from the `predicates` atom table that everything else uses.

Consequence: no test can assert anything about view behaviour, because there is
no compiled artifact to assert against.

### D2 — The size boundary bug is a data-model bug, not a coding slip

One axis (size) is partitioned by three *unrelated* predicate types with three
*different* inclusivity conventions:

| view | predicate | interval |
|------|-----------|----------|
| `Aa` Large  | `size_min` 10485760 | `[10MB, ∞)` |
| `Ab` Medium | `size_range` 1048576–10485760 | `[1MB, 10MB]` ← closed |
| `Ac` Small  | `size_max` 1048576 | `(−∞, 1MB)` |

At exactly `10485760` bytes a message matches **both** `Ab` and `Aa`. At exactly
`1048576` only `Ab` matches. The asymmetry proves this is an error, not a
convention.

No amount of care in Python fixes this class of bug. Three independent
predicates cannot be constrained to tile one axis. The model has to make
overlap unrepresentable.

### D3 — Two namespaces in one flat list, separated by a regex

Routing folders (`11`…`93`), filter views (`Aa`…`Dc`) and cosmetic section
headers (`A0 _ SIZE`, `B0 _ TIME`, …) are all sibling JMAP mailboxes. The only
thing telling them apart is:

```json
"source_folder_regex": "^[0-9]"
```

The sorter decides "is this a folder I read from, or a view I write to?" by
pattern-matching the **display name**. Any routing folder that ever fails to
start with a digit silently becomes a view source and gets rescanned.

Worse, the two namespaces have already collided once in time. `folder_renames`
records:

```
"Aa    📬 Others (fallback)" -> "91    📬 Others (fallback)"
"Ab    📥 Archive"           -> "92    📥 Archive"
"Ac    🚫 Junk"              -> "93    🚫 Junk"
```

and the current views are named `Aa 📏 Large`, `Ab 📏 Medium`, `Ac 📏 Small`.
**`Aa`/`Ab`/`Ac` were reused for a new meaning immediately after being freed.**
Nothing collides today only because the rename map keys on the *whole* display
string including emoji and label — the prefix is not the key.

### D4 — Views have no stable identity

`folders` has slugs. Views do not:

```json
{"folder": "Aa    📏 Large (≥10MB)", "predicate": {...}}
```

The display string *is* the primary key. Rename a label and you must hand-write
a `folder_renames` migration or the folder is reaped and recreated empty. That
is precisely why `folder_renames` exists — it is a workaround for a missing ID
layer that routing folders already have.

### D5 — Static and volatile views are recomputed identically

`Aa/Ab/Ac` (size) and `Da/Db/Dc` (attachments) are **immutable** for a given
message. `Ba/Bc` (time windows) and `Ca` (unread) are **volatile** and must be
re-evaluated. The sorter recomputes all nine, for up to 2000 messages, every 30
seconds. Six of nine are pure waste — and that waste is what makes the
`limit=2000` truncation bite.

### D6 — The safety net was dead (fixed 2026-08-23, `57d648ba7`)

Three rots had stacked:

1. `run-tests.sh` pointed at `a_solutions/aa-sui_tools-stalwart/src` — a path
   that ceased to exist at the `cloud-*` rename. The suite exited before a
   single assertion.
2. The fallback assertion hardcoded `"Aa    📬 Others (fallback)"`, dead since
   the `Aa→91` rename.
3. Goldens were cut 2026-06-10, predating both that rename and `inbox_copy_flags`.

Now green, and the assertion derives from `.folders[.routing_default]`.

### D7 — Stalwart routing is a strict subset, silently

`routingFrom` in the compiler only lowers `from_domain` atoms to sieve. Today
that covers 30 of 31 route rules; 1 combinator rule is dropped with no count
reported. Low impact now, but it is a cliff: any new predicate type silently
vanishes from Stalwart.

---

## 2. Design

Four changes. All of them apply the pattern that already works for routing.

### C1 — One mailbox table, with `id` and `kind`

Replace the three separate lists (`folders`, `folders_ui`, `filters.views`) with
one table where every entry has a stable slug and a declared kind:

```json
"mailboxes": {
  "sec_admin":  {"kind": "section", "prefix": "10", "label": "_ ADMIN"},
  "admin":      {"kind": "route",   "prefix": "11", "label": "🛡️ Admin & Finance", "section": "sec_admin"},
  "others":     {"kind": "route",   "prefix": "91", "label": "📬 Others (fallback)", "section": "sec_other"},
  "sec_size":   {"kind": "section", "prefix": "A0", "label": "_ SIZE"},
  "v_size_lg":  {"kind": "view",    "prefix": "Aa", "label": "📏 Large",  "section": "sec_size"}
}
```

- `kind` **replaces `source_folder_regex`**. The sorter reads `kind=="route"`,
  writes `kind=="view"`, ignores `kind=="section"`. No display-string parsing
  anywhere. D3 gone.
- Views gain slugs, so they can be referenced, tested and migrated like folders.
  D4 gone.
- Display name becomes `render(prefix, label)` — derived, never authoritative.

### C2 — Persist `slug → JMAP mailbox id`, and delete `folder_renames`

JMAP mailboxes carry a server-assigned `id`. The sorter currently rediscovers
mailboxes by name every run, which is what makes a label change destructive.

Persist the mapping once (`slug → jmapId`) in the sorter's state. Then renaming
a label is a `Mailbox/set` name update against a known id — it keeps its mail by
construction, and `folder_renames` stops being a concept that needs to exist.

### C3 — Axis model for views: make overlap unrepresentable

Views stop being a list of independent predicates and become typed axes:

```json
"axes": {
  "size":   {"kind": "partition", "of": "size_bytes",
             "bounds": [1048576, 10485760],
             "buckets": ["v_size_sm", "v_size_md", "v_size_lg"]},
  "time":   {"kind": "window", "of": "received_at", "volatile": true,
             "windows": [{"slug": "v_time_24h", "hours": 24},
                         {"slug": "v_time_7d",  "hours": 168}]},
  "state":  {"kind": "flag", "of": "unread", "volatile": true,
             "buckets": ["v_state_unread"]},
  "attach": {"kind": "predicate_set",
             "buckets": [{"slug": "v_att_any", "when": "has_attachment"},
                         {"slug": "v_att_pdf", "when": "mime_pdf"}]}
}
```

A `partition` compiles **N buckets from N−1 boundaries** under a single
inclusivity rule (half-open `[lo, hi)`). Three views become one ordered
declaration. **D2 becomes structurally impossible** — you cannot write an
overlapping partition, the same way you cannot write a duplicate JSON key.

`predicate_set` buckets reference the **existing `predicates` atom table**
(`"when": "mime_pdf"`), collapsing the second predicate language into the first.
D1's root cause gone.

`volatile: true` marks exactly the axes that need re-evaluation.

### C4 — Compile views: `toViewPlan`, golden-tested

Add a fourth lowering beside `toSieve` / `toMaddyJson`. It emits a flat,
already-decided plan:

```json
{"static":   [{"view": "v_size_lg", "test": {"op": "ge", "field": "size", "value": 10485760}}, ...],
 "volatile": [{"view": "v_time_24h", "test": {"op": "within_h", "field": "received_at", "value": 24}}, ...]}
```

Two consequences:

- The plan is golden-tested like everything else, against
  `fixtures/filter-cases.json`. Boundary cases (`1048576`, `10485760`) become
  assertions instead of hopes.
- `jmap-sorter.py` stops being an interpreter and becomes an **executor**: no
  `if ptype == ...` ladder, no per-view Python. It evaluates a compiled test
  against a message and sets membership.

Combined with `volatile`, the sorter recomputes 3 axes instead of 9 — which is
what makes the pagination fix (below) affordable.

### C5 — Report degradation instead of dropping silently (D7)

`toSieve` should count atoms it cannot lower and emit the count into the
artifact, with a golden assertion that it matches the expected number. A rise in
that number then fails CI instead of quietly shrinking Stalwart's routing.

---

## 3. Reliability fixes (independent of the above, already agreed)

These are correctness-of-execution, not correctness-of-model. They stand on
their own and should land first — they are the ones currently losing mail.

1. **Stop the silent truncation.** `email_query_in` uses `limit=2000` with no
   pagination and never reads `Email/query`'s returned `total`. maddy holds 2166
   blobs. Page until exhausted; alarm if `total` exceeds what was fetched.
2. **Incremental sync.** `Email/changes` is never called — the sorter full-queries
   every 30s with no state token. Adopt `Email/changes` + persisted state.
3. **Restart policy + heartbeat** on the sorter, so a dead sorter is visible.
4. **Invert the alarm.** With UNIFIED-INBOX, INBOX mail is `\Seen`. Unread mail
   sitting in INBOX therefore means the sorter did not run — a free liveness
   signal, currently unused.

---

## 4. Sequencing

| Phase | Change | Risk |
|-------|--------|------|
| 0 | ✅ Revive golden suite (`57d648ba7`) | none — done |
| 1 | Reliability fixes 1–4 | low, no data model change |
| 2 | C1 mailbox table + C2 id persistence, `folder_renames` retired | medium — mailbox identity migration |
| 3 | C3 axis model + C4 `toViewPlan`, sorter → executor | medium — behaviour change at boundaries |
| 4 | C5 degradation reporting | low |

Phase 1 is separable and should not wait for the rest.

Phase 2 is the only one that touches live mailbox identity; it must run once,
verify `slug → jmapId` for every mailbox, and be idempotent on re-run — the
same discipline `folder_renames` already documents for itself.
