"""Generic web crawl — httpx fetch + optional CSS-selector extraction (selectolax).

Covers the ad-hoc crawls crawlee-cloud used to run. No browser/headless — static HTML only;
if a target needs JS rendering, that's a future upgrade (playwright), not the lean default.
"""
import httpx
from selectolax.parser import HTMLParser

UA = "Mozilla/5.0 (compatible; scrappers-api/0.1; +https://api.diegonmarcos.com/scrappers)"


def scrape(url: str, selector: str | None = None, **_):
    if not url:
        raise ValueError("url required")
    with httpx.Client(follow_redirects=True, timeout=30, headers={"User-Agent": UA}) as c:
        r = c.get(url)
        r.raise_for_status()
    tree = HTMLParser(r.text)

    if selector:
        items = [n.text(strip=True) for n in tree.css(selector) if n.text(strip=True)]
        return {"url": url, "selector": selector, "items": items, "_summary": {"matched": len(items)}}

    # No selector → return page title + all links (a lightweight sitemap-ish crawl).
    title = tree.css_first("title")
    links = list({a.attributes.get("href") for a in tree.css("a[href]") if a.attributes.get("href")})
    return {
        "url": url,
        "title": title.text(strip=True) if title else "",
        "links": links,
        "_summary": {"links": len(links), "bytes": len(r.text)},
    }
