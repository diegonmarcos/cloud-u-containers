#!/usr/bin/env python3
"""jev-gate — the one Jev pre-flight gate shared by the claude, goose and hermes CLIs (#764).

Jev (typesafe/jev-1.13, OpenRouter Decisions API) answers typed questions with probabilities.
Every tunable lives in jev-gate.json beside this file; this module only applies it. Stdlib only,
because it runs inside three different images (python:3.13-slim twice, hermes' own Python).

Entry points:
  python3 jev_gate.py claude   Claude Code PermissionRequest/PreToolUse command hook (stdin JSON)
  python3 jev_gate.py goose    goose 1.44 PreToolUse plugin hook (stdin JSON)
  select_tools(request, cfg)   hermes llm_request middleware (see __init__.py)

Fail-safe contract: no key, a timeout, an HTTP error, a malformed answer or ANY exception means
"no opinion", and every adapter maps no opinion to exactly what the host would do without the gate.
"""
import hashlib
import json
import os
import re
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


def decide(state, questions, cfg):
    """POST one Decisions request. Returns (answers, meta) or (None, meta) on any failure."""
    key = _key(cfg)
    if not key:
        return None, {"error": "no_key"}
    body = json.dumps({"model": cfg["model"], "state": state, "questions": questions}).encode()
    req = urllib.request.Request(cfg["endpoint"], data=body, method="POST", headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.monotonic()
    meta = {"state_sha": hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest()[:12]}
    try:
        with urllib.request.urlopen(req, timeout=cfg["timeout_s"]) as res:
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

def safety(use, tool, tool_input, project, task, cfg):
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
    if event.get("tool_name") is None:
        return None
    ti = event.get("tool_input") or {}
    desc = ti.get("description") if isinstance(ti, dict) else None
    verdict, _ = safety("claude_permission", event["tool_name"], ti, event.get("cwd"),
                        desc if isinstance(desc, str) else None, cfg)
    if verdict != "allow":
        return None  # 'unsafe' is never turned into a deny: the normal prompt decides
    if event.get("hook_event_name") == "PreToolUse":
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                       "permissionDecisionReason": "jev-gate: confident safe"}}
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}


def goose_hook(event, cfg):
    """goose PreToolUse hook stdin -> {"decision":"block",...} or None (pass)."""
    verdict, scores = safety("goose_pretool", event.get("tool_name"), event.get("tool_input") or {},
                             event.get("working_dir"), None, cfg)
    u = use_cfg(cfg, "goose_pretool")
    if verdict == "unsafe" and u and u.get("on_unsafe") == "block":
        return {"decision": "block", "reason": "jev-gate: judged unsafe/irreversible (%s); ask the operator"
                % ", ".join("%s=%.2f" % kv for kv in sorted(scores.items()))}
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
        out = {"claude": claude_hook, "goose": goose_hook}[mode](event, cfg)
    except Exception:  # noqa: BLE001 — a broken gate must never change the host's behaviour
        out = None
    if out is not None:
        print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
