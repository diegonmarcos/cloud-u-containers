"""Apify backend — run a pre-built Apify actor and collect its dataset items.

Why: Apify hosts maintained scrapers (Instagram, TikTok, etc.) as actors; this module
just triggers a sync run and returns the resulting dataset, no scraping logic of our own.

Secret (env, from src/secrets.yaml -> sops): APIFY_TOKEN.
Docs: https://docs.apify.com/api/v2#/reference/actor-tasks/run-collection/run-actor-synchronously-and-get-dataset-items
"""
import os
import httpx

API = "https://api.apify.com/v2/acts/{actor}/run-sync-get-dataset-items"


def _token():
    token = os.environ.get("APIFY_TOKEN")
    if not token:
        raise RuntimeError("Apify needs APIFY_TOKEN (add to src/secrets.yaml)")
    return token


def scrape(actor: str, input: dict | None = None, **_):
    """Run `actor` (e.g. 'apify~instagram-scraper') synchronously and return its dataset items."""
    if not actor:
        raise ValueError("actor required")
    token = _token()
    with httpx.Client(timeout=120) as c:
        r = c.post(
            API.format(actor=actor),
            params={"token": token},
            json=input or {},
        )
        r.raise_for_status()
        items = r.json()
    return {
        "actor": actor,
        "items": items,
        "_summary": {"items": len(items), "via": "apify"},
    }
