"""Fleet embeddings + rerank + PDF text server (mesh-only).

One process: Infinity (https://github.com/michaelfeil/infinity) serves the OpenAI-compatible
POST /embeddings (bge-m3), POST /rerank (bge-reranker-v2-m3), GET /models and GET /health; this file only
adds POST /pdf (raw application/pdf body -> {pages, text}). Models and sizes come from build.json via the
environment (compose.nix); nothing is hardcoded here beyond the defaults.
"""
import os

from fastapi import HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from infinity_emb import create_server
from infinity_emb.args import EngineArgs

import pdftext

BATCH = int(os.environ.get("BATCH_SIZE", "8"))


def _args(model: str) -> EngineArgs:
    # CPU torch, no BetterTransformer (needs optimum), no warmup (a max-batch warmup doubles peak RAM).
    return EngineArgs(model_name_or_path=model, engine="torch", device="cpu", batch_size=BATCH,
                      bettertransformer=False, model_warmup=False, trust_remote_code=False)


app = create_server(engine_args_list=[
    _args(os.environ.get("EMBED_MODEL", "BAAI/bge-m3")),
    _args(os.environ.get("RERANK_MODEL", "BAAI/bge-reranker-v2-m3")),
])


@app.post("/pdf")
async def pdf(request: Request):
    data = await request.body()
    try:
        return await run_in_threadpool(pdftext.extract, data)
    except ValueError as e:
        raise HTTPException(status_code=422 if "larger" not in str(e) else 413, detail=str(e))
