#!/usr/bin/env python3
"""Maddy imap.filter.command script — delivery-time mail sorter.

Contract (see maddy source: docs/reference/storage/imap-filters.md and
internal/imap_filter/command/command.go):
  stdin  : RFC822 message (headers + body), bytes
  argv   : {account_name} {sender} {rcpt_to} {subject}
  stdout :
    line 1    : destination folder name (empty = keep default / INBOX)
    lines 2+  : IMAP keywords/flags to add to the message

Reads /data/mail-rules.json — same declarative source the old sorter used.
Emits one folder + $Sorted + tag flags. Runs per delivery, exits, no daemon,
no IMAP client. Replaces the post-hoc polling sorter that was monopolising
Maddy's IMAP backend.

Fails open: on any parse/rules error, writes to stderr and emits nothing,
so Maddy delivers the message to INBOX unmodified.
"""
import email
import email.utils
import json
import os
import sys


RULES_PATH = os.environ.get("RULES_PATH", "/data/mail-rules.json")


def load_rules(path):
    with open(path) as f:
        return json.load(f)


def walk_content_types(msg):
    """Set of lowercase content-types present in the message tree."""
    types = set()
    for part in msg.walk():
        ct = part.get_content_type()
        if ct:
            types.add(ct.lower())
    return types


def match_routing(from_domain, rules):
    for route in rules.get("routing", []):
        m = route.get("match", {})
        if m.get("type") == "from_domain" and from_domain in m.get("values", []):
            return route["folder"]
    return None


def match_tags(headers, msg_size, content_types, from_addr, account, rules):
    flags = []
    from_domain = from_addr.split("@")[-1] if "@" in from_addr else ""
    for group in rules.get("tags", []):
        for rule in group.get("rules", []):
            rtype = rule.get("type")
            hit = False
            if rtype == "from_domain":
                hit = from_domain in rule.get("values", [])
            elif rtype == "from_address":
                hit = from_addr in rule.get("values", [])
            elif rtype == "header_contains":
                hv = (headers.get(rule["header"], "") or "").lower()
                hit = any(v.lower() in hv for v in rule.get("values", []))
            elif rtype == "header_exists":
                hit = rule["header"] in headers
            elif rtype == "size_over":
                hit = msg_size >= rule.get("bytes", 0)
            elif rtype == "self_sent":
                hit = from_addr == account
            elif rtype == "has_cc":
                hit = ("Cc" in headers) or ("CC" in headers)
            elif rtype == "list_header":
                hit = "List-Unsubscribe" in headers
            elif rtype == "content_type":
                hit = rule.get("value", "").lower() in content_types
            if hit:
                flags.append(rule["flag"])
    return flags


def main():
    account = sys.argv[1] if len(sys.argv) > 1 else ""
    sender  = sys.argv[2] if len(sys.argv) > 2 else ""
    # argv[3] = rcpt_to, argv[4] = subject (placeholders) — we read from headers.

    try:
        rules = load_rules(RULES_PATH)
    except Exception as e:
        sys.stderr.write("mail-filter: rules load failed: %s\n" % e)
        return

    raw = sys.stdin.buffer.read()
    msg_size = len(raw)
    try:
        msg = email.message_from_bytes(raw)
    except Exception as e:
        sys.stderr.write("mail-filter: parse failed: %s\n" % e)
        return

    from_addr = email.utils.parseaddr(msg.get("From", sender))[1].lower()
    from_domain = from_addr.split("@")[-1] if "@" in from_addr else ""
    content_types = walk_content_types(msg)

    folder = match_routing(from_domain, rules) or rules.get("routing_default") or ""
    flags  = ["$Sorted"] + match_tags(
        msg, msg_size, content_types, from_addr,
        rules.get("account", account), rules,
    )

    out = sys.stdout
    out.write(folder + "\n")
    for f in flags:
        out.write(f + "\n")


if __name__ == "__main__":
    main()
