"""Firecrawl backend — hosted scrape API that returns clean markdown for a URL.

Why: handles JS rendering + boilerplate stripping server-side; useful as a lighter
alternative to cloudflare.py when only markdown content (not raw HTML/links) is needed.

Secret (env, from src/secrets.yaml -> sops): FIRECRAWL_API_KEY.
Docs: https://docs.firecrawl.dev/api-reference/endpoint/scrape
"""
import os
import httpx

API = "https://api.firecrawl.dev/v1/scrape"


def _key():
    key = os.environ.get("FIRECRAWL_API_KEY")
    if not key:
        raise RuntimeError("Firecrawl needs FIRECRAWL_API_KEY (add to src/secrets.yaml)")
    return key


def scrape(url: str, **_):
    """Fetch `url` via Firecrawl and return its markdown content."""
    if not url:
        raise ValueError("url required")
    key = _key()
    with httpx.Client(timeout=60) as c:
        r = c.post(
            API,
            headers={"Authorization": f"Bearer {key}"},
            json={"url": url, "formats": ["markdown"]},
        )
        r.raise_for_status()
        data = r.json()
    markdown = data.get("data", {}).get("markdown", "")
    return {
        "url": url,
        "markdown": markdown,
        "_summary": {"chars": len(markdown), "via": "firecrawl"},
    }
