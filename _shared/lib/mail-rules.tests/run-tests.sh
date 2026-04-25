#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ mail-rules.nix test runner — golden-file + sanity assertions.    ║
# ║                                                                  ║
# ║ Modes:                                                           ║
# ║   ./run-tests.sh           — diff against golden/ (CI mode)     ║
# ║   ./run-tests.sh --update  — regenerate golden/ (after intent)  ║
# ║                                                                  ║
# ║ Inputs: Stalwart's canonical rule files (authoritative source).  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CANON_DIR="$HERE/../../../aa-sui_tools-stalwart/src"
GENERAL="$CANON_DIR/mail-rules-general.json"
PROFILE="$CANON_DIR/mail-rules-profile-diego.json"
GOLDEN_DIR="$HERE/golden"
GEN_SCRIPT="$HERE/generate-golden.nix"

UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

[[ -f "$GENERAL" ]] || { echo "missing: $GENERAL" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "missing: $PROFILE" >&2; exit 1; }
command -v nix-instantiate >/dev/null || { echo "nix-instantiate required" >&2; exit 1; }
command -v jq              >/dev/null || { echo "jq required"              >&2; exit 1; }

OUT="$(nix-instantiate --eval --strict --json "$GEN_SCRIPT" \
  --arg generalPath "$GENERAL" \
  --arg profilePath "$PROFILE")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s' "$OUT" | jq -r '.sieve' > "$TMP/stalwart.sieve"
printf '%s' "$OUT" | jq    '.maddy' > "$TMP/maddy.json"

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

assert "sieve has fallback fileinto to Others (flat)" \
  grep -qF 'fileinto :copy :create "Aa    📬 Others (fallback)"' "$TMP/stalwart.sieve"

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

assert "sieve has inbox-read addflag on routes when inbox_copy.enabled" \
  test "$(grep -c 'addflag "\\\\Seen"' "$TMP/stalwart.sieve")" -gt 0

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
