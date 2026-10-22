#!/usr/bin/env bash
# Guard for the sign-in chooser page (#1083): src/sso-chooser.html is GENERATED from build.json
# (edge_auth.multi_sso providers + chooser) by src/gen-sso-chooser.py; it must stay self-contained.
#   1. the committed page equals the generator output, and dist/configs/sso-chooser.html is the same page
#      under the engine banner;
#   2. four providers (Authelia, Cloudflare One, Google, GitHub), each a plain anchor with a working
#      no-JavaScript href; the footer links to Linktree, Cloud SuperApp and Cloud Store;
#   3. nothing is fetched from a third party at runtime: no external script/style/font/image/iframe, no
#      @import, no remote url(), no tracker; the only URLs are the declared sign-in and footer links;
#   4. mutation proof: an injected remote script / stylesheet / image is caught by the checker.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$(cd "$HERE/.." && pwd)"
python3 -I "$SRC/gen-sso-chooser.py" --check || { echo "FAIL: src/sso-chooser.html differs from the generator output (run python3 src/gen-sso-chooser.py)"; exit 1; }
echo "ok: committed chooser equals the generator output"
python3 -I - "$SRC" <<'PY'
import json, os, re, sys
src = sys.argv[1]
page = open(f"{src}/sso-chooser.html").read()
dist = open(f"{src}/../dist/configs/sso-chooser.html").read()
assert dist.endswith(page) and dist[:len(dist) - len(page)].count("AUTO-GENERATED") == 1, "dist chooser must be the page under the engine banner"
print("ok: dist chooser is the generated page under the engine banner")
ms = json.load(open(f"{src}/../build.json"))["caddy_config"]["edge_auth"]["multi_sso"]
ch = ms["chooser"]

def check(t):
    ids = re.findall(r'<a class="b" id="([a-z]+)" href="([^"]+)"', t)
    assert [i for i, _ in ids] == ch["order"] == ["authelia", "cloudflare", "google", "github"], f"providers/order: {ids}"
    hrefs = dict(ids)
    assert hrefs["authelia"] == ch["authelia"]["href"]
    for p in ms["providers"]:
        assert hrefs[p["id"]] == p["prefix"] + "/start", f"no-JS href for {p['id']}"
    for lab in ("Sign in with Authelia", "Sign in with Cloudflare One", "Sign in with Google", "Sign in with GitHub"):
        assert lab in t, lab
    foot = t[t.index("<footer"):t.index("</footer>")]
    for l in ch["links"]:
        assert 'href="%s"' % l["url"] in foot, l["id"]
    assert {l["id"] for l in ch["links"]} == {"linktree", "superapp", "store"}
    allowed = {ch["authelia"]["href"], ch["home"]} | {l["url"] for l in ch["links"]}
    urls = set(re.findall(r'(?:https?:)?//[^\s"\'<>)]+', re.sub(r'<svg.*?</svg>', '', t, flags=re.S)))
    urls = {u for u in urls if not u.startswith("//www.w3.org")}
    extra = {u for u in urls if u not in allowed}
    assert not extra, f"undeclared URL(s) in the page: {sorted(extra)}"
    for pat, why in ((r'<script[^>]+src=', "external script"), (r'<link\b', "link element"), (r'@import', "@import"), (r'url\(\s*["\']?(https?:)?//', "remote url()"),
                     (r'<(img|iframe|embed|object|video|audio|source)\b', "embedded resource"), (r'\b(gtag|analytics|matomo|umami|googletagmanager|fonts\.googleapis)\b', "tracker or font host")):
        assert not re.search(pat, t, flags=re.I), why
    assert 'prefers-reduced-motion' in t and 'prefers-color-scheme' in t and 'aria-live' in t and ':focus-visible' in t, "a11y/theming hooks"

check(page)
print("ok: four providers with no-JS hrefs, footer links, no third-party request, a11y and theme hooks")
for mut, why in ((lambda t: t.replace("</head>", '<script src="https://cdn.example/x.js"></script></head>'), "remote script"),
                 (lambda t: t.replace("</head>", '<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=X"></head>'), "remote stylesheet"),
                 (lambda t: t.replace("</main>", '<img src="https://t.example/p.gif"></main>'), "remote image"),
                 (lambda t: t.replace('<li><a class="b" id="cloudflare"', '<li hidden><a class="b" id="cloudflarex"'), "missing provider")):
    try:
        check(mut(page)); sys.exit("mutation not caught: " + why)
    except AssertionError:
        print("ok: mutation caught: " + why)
PY
echo "PASS: sso-chooser"
