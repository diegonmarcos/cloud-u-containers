#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ derive-mail-rules.ts test runner — golden-file + sanity checks.  ║
# ║                                                                  ║
# ║ Modes:                                                           ║
# ║   ./run-tests.sh           — diff against golden/ (CI mode)     ║
# ║   ./run-tests.sh --update  — regenerate golden/ (after intent)  ║
# ║                                                                  ║
# ║ Inputs: Stalwart's canonical rule files (authoritative source).  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CANON_DIR="$HERE/../../../user-comm_tools-stalwart/src"
GENERAL="$CANON_DIR/mail-rules-general.json"
PROFILE="$CANON_DIR/mail-rules-profile-diego.json"
GOLDEN_DIR="$HERE/golden"
DERIVER="$HERE/../derive-mail-rules.ts"

UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

[[ -f "$GENERAL" ]] || { echo "missing: $GENERAL" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "missing: $PROFILE" >&2; exit 1; }
command -v tsx             >/dev/null || { echo "tsx required"             >&2; exit 1; }
command -v jq              >/dev/null || { echo "jq required"              >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The emitter writes both artifacts itself. This used to be
# `nix-instantiate --eval --strict --json | jq -r .sieve`, which is also why
# the old sieve golden carried a trailing blank line the real file never had:
# jq -r appends a newline to a string that already ended in one.
tsx "$DERIVER" --emit "$TMP"

mkdir -p "$GOLDEN_DIR"

diff_file() {
  local name="$1" new="$2" golden="$GOLDEN_DIR/$1"
  if (( UPDATE )); then
    cp "$new" "$golden"
    echo "updated: $name"
    return 0
  fi
  if [[ ! -f "$golden" ]]; then
    echo "FAIL: golden/$name missing. Run with --update to capture baseline." >&2
    return 1
  fi
  if ! diff -u "$golden" "$new"; then
    echo "FAIL: $name drift vs golden." >&2
    return 1
  fi
  echo "ok: $name"
}

FAIL=0
diff_file stalwart.sieve "$TMP/stalwart.sieve" || FAIL=1
diff_file maddy.json     "$TMP/maddy.json"     || FAIL=1

# ── Structural assertions (not golden — always enforced) ───────────

assert() { local msg="$1"; shift; if "$@"; then echo "ok: $msg"; else echo "FAIL: $msg" >&2; FAIL=1; fi; }

RULE_COUNT_TOTAL="$(jq '.rules|length' "$GENERAL" "$PROFILE" | awk '{s+=$1} END{print s}')"
MADDY_RULE_COUNT="$(jq '.rules | length' "$TMP/maddy.json")"
MADDY_DROPPED="$(jq '[.rules[].engines.maddy] | map(select(.=="drop")) | length' "$GENERAL" "$PROFILE" | awk '{s+=$1} END{print s}')"

# The artifacts are COMMITTED, so nothing forces a regenerate when someone
# edits a canonical. Without this, a rule change lands in git while the sieve
# and both mail-rules.json files still describe the previous one -- and the
# only symptom is mail filed by rules that are no longer in the repo.
artifacts_current() { tsx "$DERIVER" --check >/dev/null 2>&1; }
assert "committed artifacts match the canonicals (else: tsx _shared/lib/derive-mail-rules.ts)" \
  artifacts_current

assert "no duplicate rule ids in general+profile" \
  test "$(jq -r '.rules[].id' "$GENERAL" "$PROFILE" | sort | uniq -d | wc -l)" = 0

assert "maddy rule count = total - dropped" \
  test "$MADDY_RULE_COUNT" = $(( RULE_COUNT_TOTAL - MADDY_DROPPED ))

assert "every maddy rule has resolved folder or flags (not both empty)" \
  test "$(jq '[.rules[] | select((.folder == null or .folder == "") and ((.flags // []) | length == 0))] | length' "$TMP/maddy.json")" = 0

assert "every maddy route has a folder that exists in general.folders" \
  test "$(jq --slurpfile g "$GENERAL" '
    [.rules[] | select(.folder != null)]
    | map(.folder)
    | unique
    | map(. as $f | select( ($g[0].folders | to_entries | map(.value)) | index($f) | not ))
    | length
  ' "$TMP/maddy.json")" = 0

# A+B architectural contract:
# • Maddy = A only (INBOX copy + one of 7 category folders, NO tags).
# • Stalwart = A + B (routes + tag system via IMAP keywords).
# Any rule that gives Maddy a flag breaks the contract. Enforce here, not
# only in prose, so future edits can't silently reintroduce tag-emission.
assert "A+B contract: no Maddy rule emits flags" \
  test "$(jq '[.rules[] | select((.flags // []) | length > 0)] | length' "$TMP/maddy.json")" = 0

assert "A+B contract: no Maddy rule is flags-only (tag-like leak)" \
  test "$(jq '[.rules[] | select(.folder == null or .folder == "")] | length' "$TMP/maddy.json")" = 0

assert "A+B contract: every canonical tag|meta rule drops in Maddy" \
  test "$(jq -s '
    [ (.[0].rules + .[1].rules)[]
      | select((.kind == "tag" or .kind == "meta") and .engines.maddy != "drop") ]
    | length
  ' "$GENERAL" "$PROFILE")" = 0

assert "A+B contract: every canonical route rule is route_only or full in Maddy with no flags leak" \
  test "$(jq -s '
    [ (.[0].rules + .[1].rules)[]
      | select(.kind == "route" and .engines.maddy == "full") ]
    | length
  ' "$GENERAL" "$PROFILE")" = 0

assert "sieve starts with require" \
  grep -q '^require \[' "$TMP/stalwart.sieve"

# Derive the fallback folder from the data, not a literal: hardcoding the
# display name silently rotted through the Aa->91 folder rename. Read from the
# EMITTED rules, and as a full path — the fallback folder is nested under its
# section header, so the bare display name is no longer what Sieve addresses.
FALLBACK_FOLDER="$(jq -rn --slurpfile r "$TMP/stalwart-rules.json" '
  def fullpath($p; $n): if $p[$n] then fullpath($p; $p[$n]) + "/" + $n else $n end;
  $r[0] as $rules
  | fullpath($rules.folder_parents; $rules.routing_default)
')"
assert "sieve has fallback fileinto to routing_default ($FALLBACK_FOLDER)" \
  grep -qF "fileinto :copy :create \"$FALLBACK_FOLDER\"" "$TMP/stalwart.sieve"

# Spec: each routed leaf folder = 2-char prefix + TWO spaces + non-space.
# Each folders_ui entry = 2-char prefix + ONE space + non-space. Validates
# the exact naming the user specified — any future edit that collapses
# spaces or adds them fails the suite.
assert "folders spacing: every leaf matches '^AZ  X…'" \
  test "$(jq '[.folders | to_entries[] | select(.value | test("^[0-9A-Za-z]{2}    [^ ]") | not)] | length' "$GENERAL")" = 0

assert "folders_ui spacing: every parent matches '^AZ X…'" \
  test "$(jq '[.folders_ui[] | select(test("^[0-9A-Za-z]{2} [^ ]") | not)] | length' "$GENERAL")" = 0

assert "folders_ui: exactly 4 parent UI entries" \
  test "$(jq '.folders_ui | length' "$GENERAL")" = 4

# Folder taxonomy and rule set are two sources of truth that can drift apart
# silently (14/23 were declared with zero routing rules for a while and
# nothing caught it). Fail the build if any declared folder — other than the
# fallback (routing_default) and the manual archive destination — has no
# rule targeting it anywhere in general+profile.
UNREACHABLE_FOLDERS="$(jq -nr --slurpfile g "$GENERAL" --slurpfile p "$PROFILE" '
  ($g[0].folders | to_entries) as $folders
  | (($g[0].rules + $p[0].rules) | map(select(.kind=="route") | .actions.copy_to) | unique) as $targeted
  | [ $folders[]
      | select(.key != $g[0].routing_default and .key != "archive")
      | .key as $k
      | select(($targeted | index($k)) | not)
      | $k ]
  | join(", ")
')"
assert "every non-fallback, non-archive folder is targeted by at least one route rule (unreachable: ${UNREACHABLE_FOLDERS:-none})" \
  test -z "$UNREACHABLE_FOLDERS"

assert "sieve has inbox-read addflag on routes when inbox_copy.enabled" \
  test "$(grep -c 'addflag "\\\\Seen"' "$TMP/stalwart.sieve")" -gt 0

# ── Folder tree / Sieve path agreement ────────────────────────────
# In IMAP a mailbox's hierarchy IS its name, so the moment a folder is nested
# every Sieve `fileinto` naming it by the old flat path goes stale. It still
# COMPILES -- and because the routes carry `:create`, delivery then makes a
# second, top-level folder of that name and files the mail there instead.
# These assertions are the only thing standing between "folder nested" and
# "mail silently filed somewhere he will not look".

RULES_JSON="$TMP/stalwart-rules.json"

# Fail closed: an empty tree must abort, not quietly pass every check below.
assert "folder_parents is non-empty (tree resolved)" \
  test "$(jq '.folder_parents | length' "$RULES_JSON")" -gt 0

# Full path of a folder, walking folder_parents to the root.
JQ_PATHS='
  def fullpath($p; $n): if $p[$n] then fullpath($p; $p[$n]) + "/" + $n else $n end;
  . as $r | $r.folder_parents as $p
'

# Every fileinto target must equal the full path its own leaf resolves to.
# Catches both directions: a flat path left behind after nesting, and a path
# that nests a folder the tree says is at ROOT.
STALE_PATHS="$(jq -rn --slurpfile r "$RULES_JSON" --rawfile sieve "$TMP/stalwart.sieve" '
  def fullpath($p; $n): if $p[$n] then fullpath($p; $p[$n]) + "/" + $n else $n end;
  $r[0].folder_parents as $p
  | [ $sieve
      | [scan("fileinto :copy :create \"([^\"]*)\"")]
      | flatten | unique | .[]
      | . as $target
      | ($target | split("/") | last) as $leaf
      | select(fullpath($p; $leaf) != $target)
      | "\($target)  (should be: \(fullpath($p; $leaf)))" ]
  | join("; ")
')"
assert "every sieve fileinto path matches the folder tree (stale: ${STALE_PATHS:-none})" \
  test -z "$STALE_PATHS"

# A parent that is not itself a declared mailbox would be created implicitly by
# Sieve's :create and then reaped by cleanup_stale as an undeclared folder.
UNDECLARED_PARENTS="$(jq -r '
  ( (.folders_ui // []) + ((.filters.section_headers) // [])
    + ((.folders // {}) | to_entries | map(.value))
    + ((.folder_groups // []) | map(.name))
    + ((.folder_groups // []) | map((.children // {}) | to_entries | map(.value)) | flatten)
    + (((.filters.views) // []) | map(.folder)) ) as $declared
  | [ (.folder_parents // {}) | to_entries[] | .value
      | select(. as $v | $declared | index($v) | not) ]
  | unique | join(", ")
' "$RULES_JSON")"
assert "every folder_parents parent is itself a declared mailbox (undeclared: ${UNDECLARED_PARENTS:-none})" \
  test -z "$UNDECLARED_PARENTS"

# The owner's rule, asserted against the data rather than a hardcoded list:
# a folder whose prefix class has a declared "X0" header must be nested under
# exactly that header. Derived from the headers actually present, so adding a
# G0 section next year extends the check for free.
MISNESTED="$(jq -r '
  ((.folders_ui // []) + ((.filters.section_headers) // [])) as $headers
  | ($headers | map({key: .[0:1], value: .}) | from_entries) as $byclass
  | (.folder_parents // {}) as $parents
  | [ ((.folders // {}) | to_entries | map(.value))
      + ((.folder_groups // []) | map(.name))
      + (((.filters.views) // []) | map(.folder)) | .[]
      | . as $f
      | select($headers | index($f) | not)
      | select($byclass[$f[0:1]] != null)
      | select($parents[$f] != $byclass[$f[0:1]]) ]
  | join(", ")
' "$RULES_JSON")"
assert "every prefixed folder nests under its own X0 header (misnested: ${MISNESTED:-none})" \
  test -z "$MISNESTED"

# The sorter's routing list is addressed by LEAF NAME (routing.rs looks each
# folder up in `name_to_id`, keyed by JMAP `mailbox.name`). A path there
# resolves to nothing, `routing_ids` comes back empty, and the backfill logs
# "no target folder exists yet" and re-routes nothing — with every container
# still reporting healthy. Sieve is the one that wants paths.
ROUTING_PATHS="$(jq -r '
  ( ((.folders // {}) | to_entries | map(.value))
    + ((.folder_groups // []) | map((.children // {}) | to_entries | map(.value)) | flatten) ) as $leaves
  | [ (.routing // [])[] | .folder
      | select((. | contains("/")) or (. as $f | $leaves | index($f) | not)) ]
  | unique | join(", ")
' "$RULES_JSON")"
assert "every routing folder is a declared leaf name, not a path (bad: ${ROUTING_PATHS:-none})" \
  test -z "$ROUTING_PATHS"

# Nesting must never rename. The Rust sorter's `name_to_id` and the app both
# address mailboxes by leaf name, so two DISTINCT mailboxes sharing one leaf
# name make the lookup ambiguous and one of them silently wins.
#
# A view may deliberately point at a routing folder -- `junkMirror` aims the Ec
# view at `93 Junk` so the additive view engine and the exclusive route engine
# report the same set -- so views are counted only where they name a mailbox no
# routing folder already declares. Everything else must be pairwise distinct.
DUP_LEAVES="$(jq -r '
  ((.folders // {}) | to_entries | map(.value)) as $routing
  | ( $routing
      + ((.folder_groups // []) | map(.name))
      + ((.folder_groups // []) | map((.children // {}) | to_entries | map(.value)) | flatten)
      + (.folders_ui // []) + ((.filters.section_headers) // [])
      + (((.filters.views) // []) | map(.folder)
         | map(select(. as $v | $routing | index($v) | not))) )
  | group_by(.) | map(select(length > 1) | .[0]) | unique | join(", ")
' "$RULES_JSON")"
assert "no two managed mailboxes share a leaf name (dupes: ${DUP_LEAVES:-none})" \
  test -z "$DUP_LEAVES"

# ── End-to-end mail-filter.sh fixtures ────────────────────────────
# Runs the Maddy filter against each fixture case and asserts the
# emitted folder + flags match the declarative expectation.
MADDY_SRC="$HERE/../../../aa-sui_tools-maddy/src"
FILTER="$MADDY_SRC/mail-filter.sh"
FIXTURES="$HERE/fixtures/filter-cases.json"

if [[ -f "$FILTER" && -f "$FIXTURES" ]]; then
  CASES_N="$(jq '.cases | length' "$FIXTURES")"
  for i in $(seq 0 $((CASES_N - 1))); do
    label="$(jq -r ".cases[$i].label"    "$FIXTURES")"
    from="$(jq -r ".cases[$i].from"       "$FIXTURES")"
    subj="$(jq -r ".cases[$i].subject"    "$FIXTURES")"
    want_folder="$(jq -r ".cases[$i].expect_folder" "$FIXTURES")"
    want_flags_json="$(jq   -c ".cases[$i].expect_flags_include" "$FIXTURES")"

    extra_headers="$(jq -r ".cases[$i].extra_headers // empty" "$FIXTURES")"
    email="$(
      printf 'From: %s\nTo: me@diegonmarcos.com\nSubject: %s\n' "$from" "$subj"
      [[ -n "$extra_headers" ]] && printf '%s\n' "$extra_headers"
      printf '\nbody\n'
    )"
    out="$(printf '%s' "$email" | RULES_PATH="$TMP/maddy.json" "$FILTER" \
             me@diegonmarcos.com "$from" me@diegonmarcos.com "$subj" || true)"
    got_folder="$(printf '%s\n' "$out" | head -1)"
    got_flags_json="$(printf '%s\n' "$out" | tail -n +2 | jq -R . | jq -s .)"

    missing="$(jq --argjson w "$want_flags_json" --argjson g "$got_flags_json" \
      -n '[$w[] | select( . as $x | $g | index($x) | not )]')"
    missing_n="$(printf '%s' "$missing" | jq 'length')"

    if [[ "$got_folder" == "$want_folder" && "$missing_n" == "0" ]]; then
      echo "ok: filter: $label"
    else
      echo "FAIL: filter: $label" >&2
      echo "  want folder: $want_folder  got: $got_folder" >&2
      echo "  missing flags: $missing" >&2
      FAIL=1
    fi
  done
else
  echo "skip: mail-filter.sh end-to-end (filter or fixtures missing)"
fi

(( FAIL == 0 )) || exit 1
echo ""
echo "all mail-rules tests passed"
