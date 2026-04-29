#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ mail-filter.sh — Maddy delivery-time classifier (schema v2)      ║
# ║                                                                  ║
# ║ Wired via maddy.conf.tpl.tpl:                                    ║
# ║   imap_filter { command /usr/local/bin/mail-filter               ║
# ║                 {account_name} {sender} {rcpt_to} {subject} }    ║
# ║                                                                  ║
# ║ Contract:                                                        ║
# ║   stdin        = RFC822 message bytes                            ║
# ║   argv         = {account_name} {sender} {rcpt_to} {subject}     ║
# ║   stdout line 1 = destination folder (empty → INBOX)             ║
# ║   stdout 2+    = IMAP flags to add to that delivery              ║
# ║                                                                  ║
# ║ Rules come from a derived JSON produced by                       ║
# ║   _shared/lib/mail-rules.nix :: toMaddyJson                      ║
# ║ Input schema (v2):                                               ║
# ║   {                                                              ║
# ║     schema_version: 2,                                           ║
# ║     account: "…",                                                ║
# ║     routing_default: "📦 Others",                                ║
# ║     inbox_copy_flags: ["\\Seen"],   (informational; used by      ║
# ║                                      maddy.conf not this script) ║
# ║     rules: [                                                     ║
# ║       { id, priority, when, folder?, flags? }                    ║
# ║     ]                                                            ║
# ║   }                                                              ║
# ║                                                                  ║
# ║ Supported `when` predicate types:                                ║
# ║   from_domain, from_domain_suffix, from_address,                 ║
# ║   to_contains, reply_to_contains,                                ║
# ║   header_contains, header_regex, header_exists,                  ║
# ║   subject_contains, list_id_contains,                            ║
# ║   has_cc, has_bcc, list_header, self_sent,                       ║
# ║   any_of, all_of, not                                            ║
# ║                                                                  ║
# ║ NOT supported (declared `drop` for maddy in the canonical):      ║
# ║   size_over, size_under, content_type, body_contains             ║
# ║   (these need MIME/body parsing which busybox sh won't do)       ║
# ║                                                                  ║
# ║ Semantics — all matching rules contribute flags; first matching  ║
# ║ rule with a `folder` wins routing. Missing folder → INBOX.       ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

RULES="${RULES_PATH:-/data/mail-rules.json}"

ACCOUNT_NAME="${1:-}"
SENDER="${2:-}"
RCPT_TO="${3:-}"
# ARG_SUBJECT="${4:-}"   # not used — we parse the real Subject from stdin

# Capture headers (first block, up to the blank line separating body).
HEADERS="$(awk 'BEGIN{RS="";ORS=""} NR==1{print;exit}')"

# Case-insensitive header extraction. Handles folded continuation lines.
# Usage:  get_header <name>     → value (trimmed), empty if absent
get_header() {
  printf '%s\n' "$HEADERS" | awk -v n="$1" '
    BEGIN { name = tolower(n); ln = length(name) + 1 }
    /^[ \t]/ { if (capture) { sub(/^[ \t]+/, " "); val = val $0 } ; next }
    {
      capture = 0
      low = tolower($0)
      if (substr(low, 1, ln) == name ":") {
        val = substr($0, ln + 1)
        sub(/^[ \t]+/, "", val)
        capture = 1
      }
    }
    END { print val }
  '
}

# Extract address inside <…>, else first token containing @.
# Falls back to the envelope sender argv if the header is absent/broken.
addr_from_header() {
  local hdr="$1"
  [ -z "$hdr" ] && hdr="$SENDER"
  printf '%s\n' "$hdr" | awk '
    {
      if (match($0, /<[^>]+>/)) { print substr($0, RSTART+1, RLENGTH-2); exit }
      for (i=1; i<=NF; i++) if ($i ~ /@/) { gsub(/[<>,;"]/, "", $i); print $i; exit }
    }
  '
}

FROM_HDR="$(get_header From)"
TO_HDR="$(get_header To)"
CC_HDR="$(get_header Cc)"
BCC_HDR="$(get_header Bcc)"
REPLYTO_HDR="$(get_header Reply-To)"
SUBJECT_HDR="$(get_header Subject)"
LISTID_HDR="$(get_header List-Id)"

FROM_ADDR="$(addr_from_header "$FROM_HDR")"
FROM_DOMAIN="$(printf '%s' "${FROM_ADDR##*@}" | tr '[:upper:]' '[:lower:]')"

# Build a single jq input document from all the extracted pieces.
# jq then evaluates every rule against it with one process spawn, not N.
JQ_INPUT="$(
  jq -n \
    --arg acct       "$ACCOUNT_NAME" \
    --arg sender     "$SENDER" \
    --arg rcpt       "$RCPT_TO" \
    --arg from_dom   "$FROM_DOMAIN" \
    --arg from_addr  "$FROM_ADDR" \
    --arg to         "$TO_HDR" \
    --arg cc         "$CC_HDR" \
    --arg bcc        "$BCC_HDR" \
    --arg reply_to   "$REPLYTO_HDR" \
    --arg subject    "$SUBJECT_HDR" \
    --arg list_id    "$LISTID_HDR" \
    --arg headers    "$HEADERS" \
    '{
       account:    $acct,
       sender:     $sender,
       rcpt_to:    $rcpt,
       from_domain: ($from_dom // "" | ascii_downcase),
       from_address: ($from_addr // "" | ascii_downcase),
       to_hdr:     $to,
       cc_hdr:     $cc,
       bcc_hdr:    $bcc,
       reply_to_hdr: $reply_to,
       subject_hdr:  $subject,
       list_id_hdr:  $list_id,
       headers:    $headers
     }'
)"

# ── jq-side evaluator ─────────────────────────────────────────────
# Walks the `when` tree (atoms + combinators) against the extracted
# message envelope and emits { folder, flags } for every matching rule.
# Then picks first-matching folder and unions all matching flags.
# -n: don't read stdin (we've already consumed it into $HEADERS via awk).
OUT="$(jq -n -r --argjson ctx "$JQ_INPUT" --slurpfile rf "$RULES" '
  def lc($s): ($s // "") | ascii_downcase;

  # Header lookup by name (case-insensitive).
  def get_header($name):
    ($ctx.headers // "") as $h
    | ($h | split("\n"))
    | map(select(test("^" + $name + ":"; "i")))
    | if length == 0 then ""
      else .[0] | sub("^[^:]+:\\s*"; "") end;

  def header_contains($name; $vals):
    lc(get_header($name)) as $lv
    | any($vals[]; lc(.) as $needle | $lv | contains($needle));

  def atom_match:
    . as $p
    | ($p.type // "") as $t
    |  if   $t == "from_domain"         then any($p.values[]; lc(.) == $ctx.from_domain)
       elif $t == "from_domain_suffix"  then any($p.values[]; lc(.) as $s | $ctx.from_domain | endswith($s))
       elif $t == "from_address"        then any($p.values[]; lc(.) == $ctx.from_address)
       elif $t == "to_contains"         then any($p.values[]; lc(.) as $s | lc($ctx.to_hdr) | contains($s))
       elif $t == "reply_to_contains"   then any($p.values[]; lc(.) as $s | lc($ctx.reply_to_hdr) | contains($s))
       elif $t == "subject_contains"    then any($p.values[]; lc(.) as $s | lc($ctx.subject_hdr) | contains($s))
       elif $t == "list_id_contains"    then any($p.values[]; lc(.) as $s | lc($ctx.list_id_hdr) | contains($s))
       elif $t == "header_contains"     then header_contains($p.header; $p.values)
       elif $t == "header_exists"       then (get_header($p.header) | length > 0)
       elif $t == "header_regex"        then (get_header($p.header) | test($p.regex))
       elif $t == "has_cc"              then ($ctx.cc_hdr  | length > 0)
       elif $t == "has_bcc"             then ($ctx.bcc_hdr | length > 0)
       elif $t == "list_header"         then ($ctx.list_id_hdr | length > 0)
       elif $t == "self_sent"           then (lc($ctx.from_address) == lc($ctx.account))
       else false
       end;

  def match_when:
    . as $w
    |  if   $w | has("any_of") then any($w.any_of[]; match_when)
       elif $w | has("all_of") then all($w.all_of[]; match_when)
       elif $w | has("not")    then ($w["not"] | match_when | not)
       else atom_match
       end;

  ($rf[0].rules // []) as $rules
  | ($rules | map(select(.when | match_when))) as $matched
  | ($matched | map(select(.folder != null and .folder != "")) | .[0].folder // "") as $folder
  | ($matched | map(.flags // []) | add // []) as $flags
  | ($rf[0].routing_default // "") as $default
  | {
      folder: (if $folder == "" then $default else $folder end),
      flags:  ($flags | unique)
    }
')"

FOLDER="$(printf '%s' "$OUT" | jq -r '.folder // empty')"
printf '%s\n' "$FOLDER"
printf '%s' "$OUT" | jq -r '.flags[]?'
