#!/usr/bin/env python3
"""Render the sign-in chooser (infra-sec_caddy/dist/configs/sso-chooser.html, the file Caddy serves) in headless
Chromium at desktop and phone width, light and dark, with and without JavaScript; assert the page works and
loads nothing from a third party; write PNG screenshots to $OUT. Run: python3 chooser-shots.py <html> <outdir>"""
import http.server, json, os, sys, threading
from playwright.sync_api import sync_playwright

page_path, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
html = open(page_path, "rb").read()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/":
            code, ctype, body = 200, "text/html; charset=utf-8", html
        elif p.endswith("/health"):
            code, ctype, body = 200, "application/json", b'{"enabled":true}'
        elif p.endswith("/auth"):
            code, ctype, body = 401, "text/plain", b""
        else:
            code, ctype, body = 200, "text/plain", ("STUB " + self.path).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d" % srv.server_address[1]
fail = []
need = lambda c, m: (print(("ok: " if c else "FAIL: ") + m), c or fail.append(m))

with sync_playwright() as pw:
    br = pw.chromium.launch()
    for name, w, h in (("desktop", 1280, 800), ("phone", 390, 844)):
        for scheme in ("dark", "light"):
            ctx = br.new_context(viewport={"width": w, "height": h}, color_scheme=scheme, reduced_motion="no-preference")
            pg = ctx.new_page()
            foreign, errors = [], []
            pg.on("request", lambda r: foreign.append(r.url) if not r.url.startswith(base) and not r.url.startswith("data:") else None)
            pg.on("pageerror", lambda e: errors.append(str(e)))
            pg.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            pg.goto(base + "/?rd=" + "https%3A%2F%2Fsuite.diegonmarcos.com%2F", wait_until="networkidle")
            pg.wait_for_timeout(600)
            tag = "%s-%s" % (name, scheme)
            need(pg.locator("a.b:visible").count() == 4, "%s: four provider buttons visible" % tag)
            need(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth"), "%s: no horizontal scroll" % tag)
            need(pg.locator("footer a").count() == 3 and pg.locator("footer a:visible").count() == 3, "%s: three footer links" % tag)
            need(not foreign, "%s: no request leaves the origin %s" % (tag, foreign[:3]))
            need(not errors, "%s: no console/page errors %s" % (tag, errors[:3]))
            need("rd=https%3A%2F%2Fsuite.diegonmarcos.com%2F" in pg.get_attribute("#cloudflare", "href"), "%s: provider link carries rd" % tag)
            if scheme == "dark" and name == "desktop":
                pg.keyboard.press("2")
                pg.wait_for_url("**/oauth2/cloudflare/start**")
                need("/oauth2/cloudflare/start?rd=" in pg.url, "keyboard 2 opens the Cloudflare One start link")
                pg.go_back(); pg.wait_for_timeout(300)
                pg.keyboard.press("?"); need(pg.locator("#help.on").count() == 1, "? opens the key list")
                pg.keyboard.press("t"); need(pg.evaluate("document.documentElement.getAttribute('data-theme')") in ("light", "dark"), "t toggles the theme")
                pg.keyboard.press("ArrowDown"); need(pg.evaluate("document.activeElement.classList.contains('b')"), "arrow keys move focus over the providers")
            pg.screenshot(path=os.path.join(out, tag + ".png"), full_page=True)
            ctx.close()
    ctx = br.new_context(viewport={"width": 390, "height": 844}, java_script_enabled=False)
    pg = ctx.new_page(); pg.goto(base + "/")
    need(pg.locator("a.b:visible").count() == 4, "no-JS: four provider links are present and visible")
    need({pg.get_attribute("#" + i, "href") for i in ("cloudflare", "google", "github")} == {"/oauth2/cloudflare/start", "/oauth2/google/start", "/oauth2/github/start"}, "no-JS: provider links work without rd")
    pg.screenshot(path=os.path.join(out, "phone-nojs.png"), full_page=True)
    br.close()
if fail:
    print("FAILED:", fail); sys.exit(1)
print("PASS: chooser screenshots in", out)
