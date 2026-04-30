# Archived Maddy maintenance scripts (transition period)

These scripts have been **superseded** by `src/mail-sieve-subset-post-hoc.sh`
(see plan: `~/.claude/plans/maddy-sieve-subset-refactor.md`). They are kept
here as historical reference and rollback safety until the post-hoc script
has been validated on prod for at least one full cleanup cycle.

## Mapping

| Archived script | Replaced by |
|---|---|
| `dedupe-inbox.sh` | `mail-sieve-subset-post-hoc.sh apply-rules` |
| `dedupe-folders.sh` | `mail-sieve-subset-post-hoc.sh dedupe` |
| `cleanup-stale-mailboxes.sh` | `mail-sieve-subset-post-hoc.sh cleanup-mailboxes` |

## Why kept (not deleted yet)

- **Rollback safety**: if the SQL-direct post-hoc script reveals a bug on prod,
  copying any of these back to `src/` + rebuilding is one operation.
- **Behavioural reference**: the post-hoc script's tester compares semantic
  output against these (same input → same folder routing, just faster).
- **Audit trail**: easier to diff against history when explaining the change.

## Why NOT bundled into the container

`flake.nix#extraAssets` does NOT include `./z-archive`, so these scripts are
not copied into `dist/assets/` and not mounted into the maddy container.
`build.json#lifecycle` does not reference them. They are git-only.

A separate tester (`2_configs/test/test_maddy_filtering.sh`) asserts that
nothing in the active build pipeline references `src/z-archive/*` paths —
guards against accidental re-activation.

## When safe to delete

Delete in a follow-up commit once **all** of:

1. `mail-sieve-subset-post-hoc.sh` has been deployed to prod (oci-mail).
2. All five subcommands (`integrity-check`, `recover-headers`, `integrity-fix`,
   `dedupe`, `apply-rules`) have run successfully against the real ~5000-message
   prod mailbox.
3. A 30-day soak period has elapsed without any rollback need.

After that, delete this entire `z-archive/` directory + this README in one
commit titled e.g. `chore(maddy): retire pre-SQL maintenance scripts`.
