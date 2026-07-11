"""scrappers-api — unified profile-scrape + generic-crawl API (retires crawlee-cloud).

Lean, on-demand, flat-JSON output. Each platform is a module in scrapers/ exposing
scrape(**params) -> dict. Targets are data-driven (scrappers.json), scheduled by Dagu.

Env: PORT, HTTP_HOST, BASE_PATH (/scrappers), DATA_DIR (/app/data), SESSION_DIR (/app/session).
Secrets (dist/.secrets via env_file): IG_BURNER_USER, IG_BURNER_PASS (private-account burner).
"""
import os
import json
import time
import importlib
from pathlib import Path

from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.responses import JSONResponse
from pydantic import BaseModel

BASE_PATH = os.environ.get("BASE_PATH", "/scrappers").rstrip("/")
DATA_DIR = Path(os.environ.get("DATA_DIR", "/app/data"))
HERE = Path(__file__).parent

# ── data-driven targets (never hardcode handles in code) ──
TARGETS = {t["id"]: t for t in json.loads((HERE / "scrappers.json").read_text())["targets"]}
PLATFORMS = ("instagram", "pinterest", "linkedin", "crawl", "cloudflare")

app = FastAPI(
    title="Scrapers API",
    description="Unified profile-scrape + generic-crawl. Replaces crawlee-cloud.",
    version="0.1.0",
    openapi_url="/openapi.json",  # Caddy strips /scrappers; serve docs at root so the public bypass path resolves
    docs_url="/docs",
)


def _load(platform: str):
    if platform not in PLATFORMS:
        raise HTTPException(404, f"unknown platform '{platform}' (have: {', '.join(PLATFORMS)})")
    try:
        return importlib.import_module(f"scrapers.{platform}")
    except ModuleNotFoundError as e:  # pragma: no cover — module missing = deploy bug
        raise HTTPException(500, f"scraper module '{platform}' not available: {e}")


def _persist(name: str, data: dict) -> str:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    out = DATA_DIR / f"{name}.json"
    out.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    return str(out)


class ScrapeReq(BaseModel):
    handle: str | None = None      # instagram
    board_url: str | None = None   # pinterest
    url: str | None = None         # crawl
    selector: str | None = None    # crawl (CSS selector -> text list)


@app.get(f"{BASE_PATH}/health")
@app.get("/health")
def health():
    return {"status": "ok", "service": "scrappers-api", "platforms": list(PLATFORMS), "targets": len(TARGETS)}


@app.get(f"{BASE_PATH}/targets")
@app.get("/targets")  # Caddy strips the /scrappers prefix — register unprefixed too (like /health)
def list_targets():
    return {"targets": list(TARGETS.values())}


@app.post(f"{BASE_PATH}/scrape/{{platform}}")
@app.post("/scrape/{platform}")  # unprefixed twin (Caddy strips /scrappers)
def scrape(platform: str, req: ScrapeReq):
    mod = _load(platform)
    params = {k: v for k, v in req.model_dump().items() if v is not None}
    started = time.time()
    try:
        data = mod.scrape(**params)
    except Exception as e:  # scraper errors are data errors, not 500s from the API itself
        raise HTTPException(422, f"{platform} scrape failed: {e}")
    data["_meta"] = {"platform": platform, "elapsed_s": round(time.time() - started, 2), "params": params}
    path = _persist(f"{platform}-{req.handle or req.board_url or 'crawl'}".replace("/", "_")[:80], data)
    return JSONResponse({"ok": True, "written": path, "summary": data.get("_summary", {})})


@app.post(f"{BASE_PATH}/run/{{target_id}}")
@app.post("/run/{target_id}")  # unprefixed twin (Caddy strips /scrappers)
def run_target(target_id: str):
    """Run a data-driven target from scrappers.json (what Dagu calls on schedule)."""
    t = TARGETS.get(target_id)
    if not t:
        raise HTTPException(404, f"unknown target '{target_id}'")
    mod = _load(t["platform"])
    started = time.time()
    try:
        data = mod.scrape(**t.get("params", {}))
    except Exception as e:
        raise HTTPException(422, f"target '{target_id}' failed: {e}")
    data["_meta"] = {"target": target_id, "platform": t["platform"], "elapsed_s": round(time.time() - started, 2)}
    path = _persist(t.get("output", target_id), data)
    return {"ok": True, "target": target_id, "written": path, "summary": data.get("_summary", {})}


@app.post(f"{BASE_PATH}/scrape/linkedin/export")
@app.post("/scrape/linkedin/export")  # unprefixed twin (Caddy strips /scrappers)
async def linkedin_export(file: UploadFile = File(...)):
    """Parse an official LinkedIn data-export zip (zero account risk)."""
    mod = _load("linkedin")
    raw = await file.read()
    try:
        data = mod.parse_export(raw)
    except Exception as e:
        raise HTTPException(422, f"linkedin export parse failed: {e}")
    path = _persist("linkedin-export", data)
    return {"ok": True, "written": path, "summary": data.get("_summary", {})}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=os.environ.get("HTTP_HOST", "0.0.0.0"), port=int(os.environ.get("PORT", "3020")))
