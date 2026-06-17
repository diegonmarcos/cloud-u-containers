#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────
#  octocode-export.py — mirror octocode's GraphRAG into a kg-store ingest delta
# ──────────────────────────────────────────────────────────────────────────
#  octocode has no JSON dump, so we read its Lance tables directly:
#    <db>/<project-hash>/storage/graphrag_nodes.lance         (file nodes)
#    <db>/<project-hash>/storage/graphrag_relationships.lance (edges)
#    <db>/<project-hash>/storage/graphrag_git_metadata.lance  (commit_hash)
#
#  Repo→project-hash mapping is deterministic: the project dir whose
#  graphrag_git_metadata.commit_hash == `git -C /repos/<repo> rev-parse HEAD`.
#
#  Emits the EXACT kg-ingest delta shape ({nodes:[{table,id,key,properties}],
#  edges:[{table,from,to,properties}]}) consumed by kg-ingest.mjs → SurrealDB.
#  Full file-level mirror: every file node (imports/exports/symbols/functions as
#  properties; the large embedding vector is dropped — kg-store embedder is off)
#  and every relationship. Node key = "<repo>:<path>"; edge from/to reference it.
#
#  Lance column schema (verified live):
#    nodes: id,name,kind,path,description,symbols,imports,exports,functions,
#           size_lines,language,hash,embedding
#    rels : id,source,target,relation_type,description,confidence,weight
# ──────────────────────────────────────────────────────────────────────────
import os, sys, re, json, subprocess
import lance

DBROOT     = (os.environ.get("OCTOCODE_HOME", "/home/appuser")).rstrip("/") + "/.local/share/octocode"
REPOS_ROOT = os.environ.get("OCTOCODE_REPOS_ROOT", "/repos")
OUT_DIR    = os.environ.get("KG_GRAPHS_DIR", "/app/graphs")

def jarr(v):
    """octocode stores symbols/imports/exports/functions as JSON-string columns."""
    if not v:
        return []
    try:
        out = json.loads(v)
        return out if isinstance(out, list) else []
    except Exception:
        return []

def ident(s):
    """SurrealDB edge-table name must be a bare identifier (kg-ingest does ->T-> unquoted)."""
    return re.sub(r"[^a-zA-Z0-9_]", "_", str(s or "related")) or "related"

def find_project_dir(repo, commit):
    # octocode keys a project by its git-root PATH, not the indexed commit — the
    # commit drifts (a pull/submodule bump after indexing). So: (1) try an exact
    # commit_hash match (fast/unambiguous); (2) fall back to matching the project
    # dir whose sampled node paths actually exist under /repos/<repo> (path-keyed,
    # drift-proof). Without the fallback, a drifted repo (e.g. front) is skipped.
    if not os.path.isdir(DBROOT):
        return None
    cands = []
    for d in sorted(os.listdir(DBROOT)):
        sd = os.path.join(DBROOT, d, "storage")
        nodes_t = os.path.join(sd, "graphrag_nodes.lance")
        if not os.path.isdir(nodes_t):
            continue
        meta = os.path.join(sd, "graphrag_git_metadata.lance")
        try:
            rows = lance.dataset(meta).to_table().to_pylist()
            if rows and str(rows[0].get("commit_hash", "")) == commit:
                return sd
        except Exception:
            pass
        cands.append((sd, nodes_t))
    repo_root = f"{REPOS_ROOT}/{repo}"
    best, best_hits = None, 0
    for sd, nodes_t in cands:
        try:
            sample = lance.dataset(nodes_t).to_table().to_pylist()[:25]
        except Exception:
            continue
        hits = sum(1 for n in sample if n.get("path") and os.path.exists(os.path.join(repo_root, n["path"])))
        if hits > best_hits:
            best, best_hits = sd, hits
    return best if best_hits >= 5 else None

def export(repo):
    try:
        commit = subprocess.check_output(
            ["git", "-C", f"{REPOS_ROOT}/{repo}", "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL).decode().strip()
    except Exception as e:
        print(f"[export] {repo}: git rev-parse failed ({e})", file=sys.stderr)
        return None
    sd = find_project_dir(repo, commit)
    if not sd:
        print(f"[export] {repo}: NO project dir for commit {commit[:8]} — skip", file=sys.stderr)
        return None

    nrows = lance.dataset(sd + "/graphrag_nodes.lance").to_table().to_pylist()
    rrows = lance.dataset(sd + "/graphrag_relationships.lance").to_table().to_pylist()

    nodes = []
    for n in nrows:
        path = n.get("path") or n.get("id")
        if not path:
            continue
        key = f"{repo}:{path}"
        nodes.append({
            "table": "file", "id": key, "key": key, "layer": "code",
            "properties": {
                "repo": repo, "path": path, "node_type": n.get("kind"),
                "name": n.get("name"), "language": n.get("language"),
                "size_lines": int(n.get("size_lines") or 0),
                "description": n.get("description"),
                "symbols": jarr(n.get("symbols")), "imports": jarr(n.get("imports")),
                "exports": jarr(n.get("exports")), "functions": jarr(n.get("functions")),
                "hash": n.get("hash"),
            },
        })

    edges = []
    for r in rrows:
        src, tgt = r.get("source"), r.get("target")
        if not src or not tgt:
            continue
        edges.append({
            "table": ident(r.get("relation_type")),
            "from": f"{repo}:{src}", "to": f"{repo}:{tgt}",
            "properties": {
                "description": r.get("description"),
                "confidence": float(r.get("confidence") or 0),
                "weight": float(r.get("weight") or 0),
            },
        })

    os.makedirs(OUT_DIR, exist_ok=True)
    out = f"{OUT_DIR}/octocode-{repo}.json"
    with open(out, "w") as f:
        json.dump({"_meta": {"repo": repo, "layer": "code", "source": "octocode-lance",
                             "commit": commit}, "nodes": nodes, "edges": edges}, f)
    print(f"[export] {repo}: {len(nodes)} nodes + {len(edges)} edges → {out}", file=sys.stderr)
    return out

if __name__ == "__main__":
    repos = sys.argv[1:] or (os.environ.get("OCTOCODE_REPOS", "cloud").split())
    rc = 0
    for repo in repos:
        if export(repo) is None:
            rc = 1
    sys.exit(rc)
