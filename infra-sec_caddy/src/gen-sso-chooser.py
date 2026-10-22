#!/usr/bin/env python3
"""Generate src/sso-chooser.html from build.json (edge_auth.multi_sso: providers + chooser) and
src/sso-chooser.tpl.html. `--check` exits 1 when the committed file differs. Stdlib only."""
import html, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">%s</svg>'
ICON = {
    "authelia": '<path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6z"/><path d="M9.5 12l2 2 3.5-4"/>',
    "cloudflare": '<path d="M7 18a4 4 0 010-8 5.5 5.5 0 0110.6 1.2A3.4 3.4 0 0117 18z"/>',
    "google": '<circle cx="12" cy="12" r="8.5"/><path d="M12 12h8.2M17 16.2A5.5 5.5 0 1115.5 8"/>',
    "github": '<circle cx="7" cy="6" r="2"/><circle cx="7" cy="18" r="2"/><circle cx="17" cy="9" r="2"/><path d="M7 8v8M17 11c0 4-6 2-9.6 5.2"/>',
    "email": '<rect x="3.5" y="6" width="17" height="12" rx="2"/><path d="M4 7.5l8 6 8-6"/>',
    "linktree": '<path d="M12 3v18M12 8L6 13M12 11l6 4M12 6l4-3"/><circle cx="6" cy="13" r="1.4"/><circle cx="18" cy="15" r="1.4"/><circle cx="16" cy="3.5" r="1.2"/>',
    "superapp": '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
    "store": '<path d="M5 8h14l-1 12H6z"/><path d="M9 8V6a3 3 0 016 0v2"/>',
}


def build():
    bj = json.load(open(os.path.join(HERE, "..", "build.json")))
    ms = bj["caddy_config"]["edge_auth"]["multi_sso"]
    ch = ms["chooser"]
    broker = {p["id"]: p for p in ms["providers"]}
    labels = {"authelia": ch["authelia"]["label"], **{k: v["label"] for k, v in broker.items()}}
    order = ch["order"]
    assert sorted(order) == sorted(["authelia"] + list(broker)), "chooser.order must list authelia and every broker provider exactly once"
    items, provs, keys = [], [], {}
    for n, pid in enumerate(order, 1):
        href = ch["authelia"]["href"] if pid == "authelia" else broker[pid]["prefix"] + "/start"
        items.append('<li><a class="b" id="%s" href="%s"><span aria-hidden="true">%s</span><span class="t"><span class="lbl">Sign in with %s</span><span class="hint">%s</span></span><kbd aria-hidden="true">%d</kbd></a></li>'
                     % (pid, html.escape(href, True), SVG % ICON[pid], html.escape(labels[pid]), html.escape(ch["hints"][pid]), n))
        provs.append({"id": pid, **({"href": ch["authelia"]["href"]} if pid == "authelia" else {"prefix": broker[pid]["prefix"]})})
        keys[str(n)] = pid
    foot = ['<a href="%s" rel="noopener noreferrer">%s<span>%s</span></a>' % (html.escape(l["url"], True), SVG % ICON[l["id"]], html.escape(l["label"])) for l in ch["links"]]
    cfg = json.dumps({"providers": provs, "keys": keys, "home": ch["home"]}, separators=(",", ":")).replace("</", "<\\/")
    t = open(os.path.join(HERE, "sso-chooser.tpl.html")).read()
    for k, v in (("@@PROVIDERS@@", "\n".join(items)), ("@@FOOTER@@", "\n".join(foot)), ("@@CONFIG@@", cfg),
                 ("@@KEYHELP@@", "1&ndash;%d" % len(order))):
        assert t.count(k) == 1, k
        t = t.replace(k, v)
    return t


if __name__ == "__main__":
    out = os.path.join(HERE, "sso-chooser.html")
    new = build()
    if "--check" in sys.argv:
        sys.exit(0 if open(out).read() == new else 1)
    open(out, "w").write(new)
