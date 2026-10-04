#!/usr/bin/env python3
"""jev-gate — the one Jev pre-flight gate shared by the claude, goose and hermes CLIs (#764).

Jev (typesafe/jev-1.13, OpenRouter Decisions API) answers typed questions with probabilities.
Every tunable lives in jev-gate.json beside this file; this module only applies it. Stdlib only,
because it runs inside three different images (python:3.13-slim twice, hermes' own Python).

Entry points:
  python3 jev_gate.py claude        Claude Code PermissionRequest/PreToolUse/UserPromptSubmit hook (stdin JSON)
  python3 jev_gate.py goose         goose 1.44 PreToolUse plugin hook (stdin JSON)
  python3 jev_gate.py goose-prompt  goose 1.44 UserPromptSubmit plugin hook -> $GOOSE_MOIM_MESSAGE_FILE
  select_tools(request, cfg)        hermes llm_request middleware (see __init__.py)
  route_context(cli, prompt, ...)   hermes pre_llm_call hook (see __init__.py)

#765: Jev cannot call tools, so the gate does. route_context asks Jev whether a prompt needs code-graph
context and, on a confident pick, runs that cloud-cgc MCP lookup and returns capped text to inject;
safety() adds the touched files' code-graph impact to the state Jev scores.

Fail-safe contract: no key, a timeout, an HTTP error, a malformed answer or ANY exception means
"no opinion", and every adapter maps no opinion to exactly what the host would do without the gate.
"""
import hashlib
import json
import os
import re
import shlex
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def load_config(path=None):
    with open(path or os.environ.get("JEV_GATE_CONFIG") or os.path.join(HERE, "jev-gate.json")) as f:
        return json.load(f)


def use_cfg(cfg, use):
    u = cfg["uses"].get(use) or {}
    return u if u.get("enabled") else None


# ── redaction ────────────────────────────────────────────────────────────────

def redact(text, cfg):
    r = cfg["redact"]
    for p in r["patterns"]:
        text = re.sub(p["re"], p["sub"], text)
    secret_name = re.compile(r["env_name"])
    for name, value in os.environ.items():
        if secret_name.search(name) and len(value) >= r["env_min_len"]:
            text = text.replace(value, r["mask"])
    return text


# ── static never-auto-approve list ───────────────────────────────────────────

def _normalize(part, patterns):
    current = part
    while True:
        nxt = current.strip()
        for p in patterns:
            nxt = re.sub(p, "", nxt)
        if nxt == current:
            return current
        current = nxt


def never_auto_approve(tool, tool_input, cfg):
    """True when the call must stay with the host's normal flow without asking Jev."""
    n = cfg["never_auto_approve"]
    paths = re.compile(n["paths"], re.I)
    if tool in cfg["shell_tools"]:
        cmd = tool_input.get("command")
        if not isinstance(cmd, str):
            return True
        if re.search(n["opaque_shell"], cmd) or paths.search(cmd):
            return True
        parts = (_normalize(p, n["normalize"]) for p in re.split(n["split"], cmd))
        return any(re.search(rx, p) for p in parts if p for rx in n["commands"])
    return any(isinstance(tool_input.get(f), str) and paths.search(tool_input[f]) for f in cfg["path_fields"])


# ── the Decisions call ───────────────────────────────────────────────────────

def _key(cfg):
    return next((os.environ[k] for k in cfg["key_env"] if os.environ.get(k)), None)


def decide(state, questions, cfg, budget=None):
    """POST one Decisions request. Returns (answers, meta) or (None, meta) on any failure.
    budget: seconds left of a caller's deadline; the call never waits longer than that."""
    key = _key(cfg)
    if not key:
        return None, {"error": "no_key"}
    body = json.dumps({"model": cfg["model"], "state": state, "questions": questions}).encode()
    req = urllib.request.Request(cfg["endpoint"], data=body, method="POST", headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.monotonic()
    meta = {"state_sha": hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest()[:12]}
    try:
        if budget is not None and budget <= 0:
            raise TimeoutError("budget spent")
        with urllib.request.urlopen(req, timeout=min(cfg["timeout_s"], budget or cfg["timeout_s"])) as res:
            meta["status"] = res.status
            data = json.loads(res.read())
        meta.update(id=data.get("id"), cost=(data.get("usage") or {}).get("cost"))
        answers = data["answers"]
        if not isinstance(answers, dict):
            raise ValueError("answers is not an object")
        return answers, meta
    except Exception as e:  # noqa: BLE001 — every failure is "no opinion"
        meta["error"] = type(e).__name__ + (":%s" % e.code if hasattr(e, "code") else "")
        return None, meta
    finally:
        meta["latency_ms"] = int((time.monotonic() - t0) * 1000)


def _prob(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and 0 <= x <= 1


def log(cfg, **event):
    """Append one JSONL decision. Never the state text. Never raises."""
    try:
        path = os.path.expanduser(os.environ.get("JEV_GATE_LOG") or cfg["log_path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(json.dumps({"ts": int(time.time()), **event}) + "\n")
    except Exception:  # noqa: BLE001
        pass


# ── safety verdict (claude + goose) ──────────────────────────────────────────

def safety(use, tool, tool_input, project, task, cfg, cli=None, session_id=None):
    """Returns (verdict, scores): 'allow' | 'unsafe' | 'defer'. Never raises."""
    u = use_cfg(cfg, use)
    if not u or not isinstance(tool_input, dict):
        return "defer", None
    try:
        if never_auto_approve(tool, tool_input, cfg):
            log(cfg, use=use, tool=tool, verdict="defer", reason="never_auto_approve")
            return "defer", None
        state = {"tool": tool, "input": redact(json.dumps(tool_input, ensure_ascii=False), cfg),
                 "project": redact(project or "", cfg)}
        if task:
            state["task"] = redact(task, cfg)
        if len(json.dumps(state)) > cfg["max_state_chars"]:
            log(cfg, use=use, tool=tool, verdict="defer", reason="state_too_large")
            return "defer", None
        imp = impact(cli, tool, tool_input, project, session_id, cfg) if cli else None
        if imp and len(json.dumps(dict(state, impact=imp))) <= cfg["max_state_chars"]:
            state["impact"] = imp
        asked = {k: {kk: vv for kk, vv in q.items() if kk != "needs"}
                 for k, q in cfg["questions"].items()
                 if not k.startswith("_") and (not q.get("needs") or q["needs"] in state)}
        answers, meta = decide(state, asked, cfg)
        scores = {k: (answers.get(k) or {}).get("noul") for k in asked} if answers else None
        if not scores or not all(_prob(s) for s in scores.values()):
            log(cfg, use=use, tool=tool, verdict=u["on_error"], reason="error", **meta)
            return "defer", None
        t = u["threshold"]
        verdict = ("allow" if all(s >= t for s in scores.values())
                   else "unsafe" if all(s <= 1 - t for s in scores.values()) else "defer")
        log(cfg, use=use, tool=tool, verdict=verdict, scores=scores, threshold=t, **meta)
        return verdict, scores
    except Exception as e:  # noqa: BLE001
        log(cfg, use=use, tool=tool, verdict="defer", reason="exception:" + type(e).__name__)
        return "defer", None


def claude_hook(event, cfg):
    """Claude Code hook stdin -> stdout JSON, or None to leave the permission flow unchanged."""
    if event.get("hook_event_name") == "UserPromptSubmit":
        text = route_context("claude", event.get("prompt"), event.get("session_id"), event.get("cwd"), cfg)
        return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": text}} if text else None
    if event.get("tool_name") is None:
        return None
    ti = event.get("tool_input") or {}
    desc = ti.get("description") if isinstance(ti, dict) else None
    verdict, _ = safety("claude_permission", event["tool_name"], ti, event.get("cwd"),
                        desc if isinstance(desc, str) else None, cfg, "claude", event.get("session_id"))
    if verdict != "allow":
        return None  # 'unsafe' is never turned into a deny: the normal prompt decides
    if event.get("hook_event_name") == "PreToolUse":
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                       "permissionDecisionReason": "jev-gate: confident safe"}}
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}


def goose_hook(event, cfg):
    """goose PreToolUse hook stdin -> {"decision":"block",...} or None (pass)."""
    verdict, scores = safety("goose_pretool", event.get("tool_name"), event.get("tool_input") or {},
                             event.get("working_dir"), None, cfg, "goose", event.get("session_id"))
    u = use_cfg(cfg, "goose_pretool")
    if verdict == "unsafe" and u and u.get("on_unsafe") == "block":
        return {"decision": "block", "reason": "jev-gate: judged unsafe/irreversible (%s); ask the operator"
                % ", ".join("%s=%.2f" % kv for kv in sorted(scores.items()))}
    return None


def goose_prompt_hook(event, cfg):
    """goose UserPromptSubmit. goose 1.44 discards this hook's output (HookManager::emit), so the context
    goes to the file its built-in tom extension injects into every model call of the turn:
    $GOOSE_MOIM_MESSAGE_FILE, which start.sh exports for goosed. The file is emptied FIRST and rewritten
    only with fresh context, so a failure, a timeout kill or a 'none' never leaves an older prompt's
    context behind. ponytail: goosed reads ONE file for all its sessions, so two concurrent sessions
    see the latest prompt's context; per-session files need a goose-side hook output channel."""
    path = os.environ.get("GOOSE_MOIM_MESSAGE_FILE")
    if not path:
        return None
    path = os.path.expanduser(path)
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        open(path, "w").close()
        text = route_context("goose", event.get("message"), event.get("session_id"),
                             event.get("working_dir") or os.getcwd(), cfg)
        if text:
            with open(path + ".tmp", "w") as f:
                f.write(text)
            os.replace(path + ".tmp", path)
    except Exception:  # noqa: BLE001
        pass
    return None


# ── code-graph context (cloud-cgc MCP) ───────────────────────────────────────

def _expand(s, strict=False):
    """${VAR} / ${VAR:-default} and a leading ~. strict: an unset VAR without default -> None."""
    missing = []

    def sub(m):
        v = os.environ.get(m.group(1))
        if v:
            return v
        if m.group(2) is None:
            missing.append(m.group(1))
        return m.group(2) or ""
    out = os.path.expanduser(re.sub(r"\$\{(\w+)(?::-([^}]*))?\}", sub, s))
    return None if strict and missing else out


def mini_yaml(text):
    """Block-style YAML mappings of scalars -> nested dicts; list items are skipped. Enough for the
    MCP server blocks goose and hermes keep in config.yaml. ponytail: no flow style, no multi-line
    scalars, no anchors; swap in PyYAML if a client config ever needs them."""
    root = {}
    stack = [(-1, root)]
    for line in text.splitlines():
        body = line.split(" #", 1)[0].rstrip()
        stripped = body.lstrip()
        if not stripped or stripped.startswith(("#", "- ", "-\t")) or stripped == "-":
            continue
        key, sep, val = stripped.partition(":")
        if not sep:
            continue
        indent = len(body) - len(stripped)
        while stack[-1][0] >= indent:
            stack.pop()
        parent = stack[-1][1]
        key, val = key.strip().strip("'\""), val.strip()
        if val:
            parent[key] = val.strip("'\"")
        else:
            parent[key] = {}
            stack.append((indent, parent[key]))
    return root


def cgc_endpoint(cli, cfg):
    """The first code_graph.servers entry the CLI's own MCP config declares, with its own headers."""
    g = cfg["code_graph"]
    c = g["client_configs"].get(cli)
    if not c:
        return None
    path = _expand(c["path"])
    with open(path) as f:
        text = f.read()
    servers = (json.loads(text) if path.endswith(".json") else mini_yaml(text)).get(c["servers_key"]) or {}
    for name in g["servers"]:
        s = servers.get(name)
        if not isinstance(s, dict) or str(s.get("enabled", True)).lower() == "false":
            continue
        url = s.get("url") or s.get("uri")
        headers = {k: _expand(v, strict=True) for k, v in (s.get("headers") or {}).items() if isinstance(v, str)}
        if isinstance(url, str) and url.startswith(("http://", "https://")) and None not in headers.values():
            return {"server": name, "url": url, "headers": headers}
    return None


def mcp_session(ep, deadline, cfg):
    """Initialize one streamable-HTTP MCP session; returns rpc(method, params) bound to it."""
    g = cfg["code_graph"]
    sid, ids = [], [0]

    def rpc(method, params=None, notify=False):
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("code_graph budget spent")
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            ids[0] += 1
            body["id"] = ids[0]
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **ep["headers"]}
        if sid:
            h["Mcp-Session-Id"] = sid[0]
        req = urllib.request.Request(ep["url"], data=json.dumps(body).encode(), method="POST", headers=h)
        with urllib.request.urlopen(req, timeout=left) as res:
            if res.headers.get("Mcp-Session-Id"):
                sid[:] = [res.headers["Mcp-Session-Id"]]
            ctype = res.headers.get("Content-Type") or ""
            raw = res.read(g["max_response_bytes"] + 1)
        if notify:
            return None
        if len(raw) > g["max_response_bytes"]:
            raise ValueError("response too large")
        text = raw.decode("utf-8", "replace")
        if "event-stream" in ctype:
            msgs = []
            for ev in text.replace("\r\n", "\n").split("\n\n"):
                data = "\n".join(l[5:].lstrip() for l in ev.split("\n") if l.startswith("data:"))
                if data:
                    msgs.append(json.loads(data))
        else:
            msgs = [json.loads(text)]
        msg = next(m for m in msgs if isinstance(m, dict) and m.get("id") == body["id"])
        if "error" in msg:
            raise RuntimeError("mcp error %s" % (msg["error"] or {}).get("code"))
        return msg["result"]

    rpc("initialize", {"protocolVersion": g["protocol_version"], "capabilities": {},
                       "clientInfo": {"name": "jev-gate", "version": "1.1.0"}})
    rpc("notifications/initialized", notify=True)
    return rpc


def _tool_text(rpc, tool, args):
    r = rpc("tools/call", {"name": tool, "arguments": args})
    if r.get("isError"):
        raise RuntimeError("tool error")
    return "\n".join(c.get("text", "") for c in r.get("content") or [] if c.get("type") == "text")


def repo_of(path):
    """The nearest ancestor of path holding a .git (dir, or file for a worktree), or None."""
    d = os.path.abspath(path)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up


def _session_cache(cfg, session_id):
    if not session_id:
        return None, {}
    path = os.path.join(_expand(cfg["code_graph"]["cache_dir"]),
                        hashlib.sha256(str(session_id).encode()).hexdigest()[:16] + ".json")
    try:
        with open(path) as f:
            return path, json.load(f)
    except Exception:  # noqa: BLE001 — no or unreadable cache = empty cache
        return path, {}


def _cache_put(cfg, path, cache, key, value):
    cache[key] = value
    if not path:
        return
    for k in list(cache)[:-cfg["code_graph"]["cache_max_entries"]]:
        del cache[k]
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w") as f:
            json.dump(cache, f)
        os.replace(path + ".tmp", path)
    except Exception:  # noqa: BLE001
        pass


def _sha(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def _pick(answers, q):
    a = (answers or {}).get(q) or {}
    choice = a.get("choice")
    p = (a.get("probabilities") or {}).get(choice) if isinstance(choice, str) else None
    return choice, p


def route_context(cli, prompt, session_id, cwd, cfg):
    """Code-graph context for one user prompt as capped text, or None. Never raises."""
    u = use_cfg(cfg, "code_context")
    if not u or not isinstance(prompt, str) or not prompt.strip():
        return None
    t0 = time.monotonic()
    ev = {"use": "code_context", "cli": cli}
    try:
        r = cfg["code_graph"]["route"]
        deadline = t0 + r["budget_s"]
        query = redact(prompt, cfg)[:r["query_chars"]]
        root = repo_of(cwd) if isinstance(cwd, str) and cwd else None
        cpath, cache = _session_cache(cfg, session_id)
        key = "route:" + _sha(query + "\0" + (root or ""))
        if key in cache:
            log(cfg, verdict="cached", bytes=len(cache[key]), **ev)
            return cache[key] or None
        criteria = {k: o["criterion"] for k, o in r["options"].items()}
        criteria["none"] = r["none_criterion"]
        answers, meta = decide({"request": query}, {"route": {
            "type": "choice", "instructions": r["instructions"], "criteria": criteria}}, cfg,
            deadline - time.monotonic())
        choice, p = _pick(answers, "route")
        if not _prob(p) or choice not in criteria:
            log(cfg, verdict="none", reason="error", **meta, **ev)
            return None
        ev.update(choice=choice, p=p, threshold=u["threshold"])
        if choice == "none" or p < u["threshold"]:
            log(cfg, verdict="none", **meta, **ev)
            _cache_put(cfg, cpath, cache, key, "")
            return None
        opt = r["options"][choice]
        ep = cgc_endpoint(cli, cfg)
        if not ep:
            log(cfg, verdict="none", reason="no_endpoint", **ev)
            return None
        ev["server"] = ep["server"]
        rpc = mcp_session(ep, deadline, cfg)
        ekey = "enum:%s:%s" % (ep["server"], opt["tool"])
        if ekey not in cache:
            tool = next(t for t in rpc("tools/list", {})["tools"] if t.get("name") == opt["tool"])
            prop = ((tool.get("inputSchema") or {}).get("properties") or {}).get(r["repo_arg"]) or {}
            _cache_put(cfg, cpath, cache, ekey, prop.get("enum") or [])
        repos = cache[ekey]
        repo = os.path.basename(root) if root else None
        if repos and repo not in repos:
            answers, _ = decide({"request": query}, {"repo": {
                "type": "choice", "instructions": r["repo_instructions"], "criteria": {x: x for x in repos}}},
                cfg, deadline - time.monotonic())
            repo, rp = _pick(answers, "repo")
            if not _prob(rp) or rp < u["threshold"] or repo not in repos:
                log(cfg, verdict="none", reason="repo_unsure", **ev)
                _cache_put(cfg, cpath, cache, key, "")
                return None
        if not repo:
            log(cfg, verdict="none", reason="no_repo", **ev)
            return None
        text = _tool_text(rpc, opt["tool"], dict(opt["args"], **{r["query_arg"]: query, r["repo_arg"]: repo}))
        drop = [re.compile(x) for x in r["drop_lines"]]
        text = "\n".join(l for l in text.splitlines() if not any(d.search(l) for d in drop)).strip()
        text = redact(text, cfg)
        head = '<code-graph-context source="%s %s" repo="%s" route="%s" p="%.2f">\n' % (
            ep["server"], opt["tool"], repo, choice, p)
        tail = "\n</code-graph-context>"
        room = r["max_inject_chars"] - len(head) - len(tail)
        if len(text) > room:
            text = text[:max(room - 14, 0)] + "\n[truncated]"
        out = head + text + tail if text else ""
        _cache_put(cfg, cpath, cache, key, out)
        log(cfg, verdict="injected" if out else "empty", repo=repo, bytes=len(out),
            latency_ms=int((time.monotonic() - t0) * 1000), **ev)
        return out or None
    except Exception as e:  # noqa: BLE001 — every failure is "inject nothing"
        log(cfg, verdict="none", reason="exception:" + type(e).__name__,
            latency_ms=int((time.monotonic() - t0) * 1000), **ev)
        return None


def touched_paths(tool, tool_input, cwd, cfg):
    """(repo_root, abs_path) of files the call touches: path fields of file tools, and the words of a
    shell command that name an existing file. Capped at code_graph.impact.max_paths."""
    if tool in cfg["shell_tools"]:
        try:
            words = shlex.split(tool_input.get("command") or "")
        except ValueError:
            return []
        cands = [w for w in words if not w.startswith("-") and ("/" in w or "." in w)]
    else:
        cands = [tool_input[f] for f in cfg["path_fields"] if isinstance(tool_input.get(f), str)]
    out = []
    for c in cands:
        p = os.path.normpath(os.path.join(cwd or os.getcwd(), os.path.expanduser(c)))
        if tool in cfg["shell_tools"] and not os.path.isfile(p):
            continue
        root = repo_of(os.path.dirname(p))
        if root and (root, p) not in out:
            out.append((root, p))
    return out[:cfg["code_graph"]["impact"]["max_paths"]]


def impact(cli, tool, tool_input, cwd, session_id, cfg):
    """Capped code-graph impact text for the files a tool call touches, or None. Never raises:
    any failure means the safety state goes out exactly as it did without this."""
    i = cfg["code_graph"]["impact"]
    if not i.get("enabled"):
        return None
    try:
        nodes = [i["node_key"].format(repo=os.path.basename(root), path=os.path.relpath(p, root))
                 for root, p in touched_paths(tool, tool_input, cwd, cfg)]
        if not nodes:
            return None
        cpath, cache = _session_cache(cfg, session_id)
        rpc = None
        no_match = re.compile(i["no_match"])
        parts = []
        for n in nodes:
            key = "impact:" + n
            if key not in cache:
                if rpc is None:
                    ep = cgc_endpoint(cli, cfg)
                    if not ep:
                        return None
                    rpc = mcp_session(ep, time.monotonic() + i["budget_s"], cfg)
                t = _tool_text(rpc, i["tool"], dict(i["args"], **{i["target_arg"]: n})).strip()
                _cache_put(cfg, cpath, cache, key, "" if no_match.search(t) else t)
            if cache[key]:
                parts.append(cache[key])
        text = redact("\n".join(parts), cfg)[:i["max_chars"]]
        return text or None
    except Exception as e:  # noqa: BLE001
        log(cfg, use="impact", cli=cli, tool=tool, reason="exception:" + type(e).__name__)
        return None


# ── tool selection (hermes) ──────────────────────────────────────────────────

def _tool_name(t):
    return (t.get("function") or {}).get("name") or t.get("name")


def _tool_desc(t):
    return (t.get("function") or {}).get("description") or t.get("description") or ""


def _last_user_text(messages):
    for m in reversed(messages or []):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return c if isinstance(c, str) and c.strip() else None
    return None


def _has_tool_traffic(messages):
    return any(m.get("role") == "tool" or m.get("tool_calls") for m in messages or [])


def select_tools(request, cfg, api_call_count=1, api_mode="chat_completions"):
    """Return a replacement request with a narrowed `tools` list, or None to leave it untouched."""
    u = use_cfg(cfg, "hermes_tool_select")
    if not u or not isinstance(request, dict):
        return None
    try:
        if (u.get("first_call_only") and api_call_count != 1) or api_mode not in u["api_modes"]:
            return None
        tools = request.get("tools") or []
        names = [_tool_name(t) for t in tools]
        prompt = _last_user_text(request.get("messages"))
        if not tools or not prompt or not all(names) or len(tools) > u["max_options"] \
                or isinstance(request.get("tool_choice"), dict):
            return None
        criteria = {n: redact(_tool_desc(t), cfg)[:u["description_chars"]] or n for n, t in zip(names, tools)}
        criteria.setdefault("none", "No tool is needed; answer directly in text.")
        state = {"request": redact(prompt, cfg)[:cfg["max_state_chars"]]}
        answers, meta = decide(state, {"tool": {"type": "choice", "instructions": cfg["tool_pick_instructions"],
                                                "criteria": criteria}}, cfg)
        a = (answers or {}).get("tool") or {}
        choice, probs = a.get("choice"), a.get("probabilities") or {}
        p = probs.get(choice)
        if not _prob(p):  # an out-of-set choice raises at names.index below -> on_error
            log(cfg, use="hermes_tool_select", verdict=u["on_error"], reason="error", options=len(criteria), **meta)
            return _without_tools(request) if u["on_error"] == "no_tools" else None
        top = dict(sorted(probs.items(), key=lambda kv: -kv[1] if _prob(kv[1]) else 0)[:3])
        if p < u["threshold"]:
            log(cfg, use="hermes_tool_select", verdict="all_tools", choice=choice, p=p, top=top,
                threshold=u["threshold"], options=len(criteria), **meta)
            return None
        if choice == "none":
            out = None if _has_tool_traffic(request.get("messages")) else _without_tools(request)
        else:
            out = dict(request, tools=[tools[names.index(choice)]])
        log(cfg, use="hermes_tool_select", verdict="narrowed" if out else "all_tools", choice=choice, p=p,
            top=top, threshold=u["threshold"], options=len(criteria), **meta)
        return out
    except Exception as e:  # noqa: BLE001
        log(cfg, use="hermes_tool_select", verdict=u["on_error"], reason="exception:" + type(e).__name__)
        return _without_tools(request) if u["on_error"] == "no_tools" else None


def _without_tools(request):
    return {k: v for k, v in request.items() if k not in ("tools", "tool_choice", "parallel_tool_calls")}


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    try:
        cfg = load_config()
        event = json.loads(sys.stdin.read())
        out = {"claude": claude_hook, "goose": goose_hook, "goose-prompt": goose_prompt_hook}[mode](event, cfg)
    except Exception:  # noqa: BLE001 — a broken gate must never change the host's behaviour
        out = None
    if out is not None:
        print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
