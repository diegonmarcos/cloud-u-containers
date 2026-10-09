#!/usr/bin/env python3
"""G0 _ AUTH parity: the maddy auth-axis rules are exactly what the declared pattern set says, and the three
classes are exclusive and exhaustive for any Subject. Usage: auth_patterns_parity.py <maddy.json> [vendored.json]

Optional second argument: the Cloud Mail app's vendored copy of the pattern set; it must be byte-equal in
content to _shared/mail-auth-patterns.json (the app's own test holds its classifier to that copy).
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATTERNS = os.path.join(HERE, "..", "..", "mail-auth-patterns.json")
pat = json.load(open(PATTERNS, encoding="utf-8"))
rules = json.load(open(sys.argv[1], encoding="utf-8"))["rules"]
auth = [r for r in rules if r.get("axis") == "auth"]
bad = []

if [r["folder"] for r in auth] != [pat["classes"][k]["folder"] for k in ("Ga", "Gb", "Gc")]:
    bad.append("auth folders are not Ga, Gb, Gc as declared")


def ev(node, subject):
    """Evaluate a predicate tree on a Subject exactly as the sorter does (case-insensitive substring)."""
    if "any_of" in node:
        return any(ev(c, subject) for c in node["any_of"])
    if "all_of" in node:
        return all(ev(c, subject) for c in node["all_of"])
    if "not" in node:
        return not ev(node["not"], subject)
    assert node["type"] == "header_contains" and node["header"] == "Subject", node
    return any(v.lower() in subject.lower() for v in node["values"])


def first_match(subject):
    for r in auth:
        if ev(r["when"], subject):
            return r["folder"][:2]
    return None


# the value lists are the declared ones, verbatim
by = {r["folder"][:2]: r["when"] for r in auth}
if by["Ga"]["values"] != pat["code_subject_phrases"]:
    bad.append("Ga values differ from code_subject_phrases")
link_leaf = by["Gb"]["all_of"][0]
if link_leaf["values"] != pat["link_phrases"]:
    bad.append("Gb values differ from link_phrases")

# every declared phrase classifies as its class; a code phrase wins over a link phrase (Ga before Gb)
for ph in pat["code_subject_phrases"]:
    if first_match(f"Re: {ph.upper()} 123456") != "Ga":
        bad.append(f"code phrase {ph!r} is not Ga")
for ph in pat["link_phrases"]:
    got = first_match(f"Please {ph}")
    if got != "Gb":
        bad.append(f"link phrase {ph!r} is {got}, not Gb")
if first_match("Your verification code - or reset your password") != "Ga":
    bad.append("a subject with both a code and a link phrase must be Ga")
for neutral in ("Weekly gardening newsletter", "Your invoice is ready", ""):
    if first_match(neutral) != "Gc":
        bad.append(f"{neutral!r} must be Gc")

# exclusive and exhaustive: exactly one class decides any subject, whichever rule order is tried
import itertools
probe = [""] + pat["code_subject_phrases"] + pat["link_phrases"] + [a + " " + b for a, b in itertools.product(pat["code_subject_phrases"][:3], pat["link_phrases"][:3])] + ["hello"]
for s in probe:
    hits = [r["folder"][:2] for r in auth if ev(r["when"], s)]
    if len(hits) != 1:
        bad.append(f"{s!r} matched {hits}: classes must be exclusive and exhaustive")

if len(sys.argv) > 2:
    vend = json.load(open(sys.argv[2], encoding="utf-8"))
    if vend != pat:
        bad.append("the vendored copy differs from _shared/mail-auth-patterns.json")

for b in bad:
    print("    " + b)
sys.exit(1 if bad else 0)
