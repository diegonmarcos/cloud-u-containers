#!/usr/bin/env python3
"""#764 tester for _shared/jev-gate: behaviour against a mock Decisions server, mutation tests
that prove each guard is load-bearing, and the wiring into the claude, goose and hermes containers.

Run from anywhere: python3 _shared/test-jev-gate.py   (stdlib only, no network, no key)
"""
import copy
import http.server
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE_DIR = os.path.join(ROOT, "_shared", "jev-gate")
FAKE_KEY = "sk-or-v1-" + "f" * 64


# ── mock Decisions server ────────────────────────────────────────────────────

class Mock:
    reply = None     # dict answers | callable(body)->answers
    status = 200
    raw = None       # bytes body override
    delay = 0.0
    bodies = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Mock.bodies.append({"body": body, "auth": self.headers.get("Authorization")})
        time.sleep(Mock.delay)
        if Mock.raw is not None:
            out = Mock.raw
        else:
            answers = Mock.reply(body) if callable(Mock.reply) else Mock.reply
            out = json.dumps({"id": "gen-dec-test", "model": "typesafe/jev-1.13-test", "answers": answers,
                              "usage": {"input_tokens": 1, "output_tokens": 1, "cost": 0.0000001}}).encode()
        try:
            self.send_response(Mock.status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)
        except OSError:
            pass  # client gave up (timeout case)


SERVER = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
TMP = tempfile.mkdtemp(prefix="jev-gate-test-")


def reset(reply=None, status=200, raw=None, delay=0.0):
    Mock.reply, Mock.status, Mock.raw, Mock.delay, Mock.bodies = reply, status, raw, delay, []


def nouls(**scores):
    return lambda body: {k: {"type": "noul", "noul": scores.get(k, scores.get("all"))} for k in body["questions"]}


def choice(name, p, others=None):
    def f(body):
        crit = body["questions"]["tool"]["criteria"]
        probs = {k: 0.0 for k in crit}
        probs.update(others or {})
        probs[name] = p
        return {"tool": {"type": "choice", "choice": name, "confidence": p, "probabilities": probs}}
    return f


def test_config(mod):
    cfg = mod.load_config(os.path.join(GATE_DIR, "jev-gate.json"))
    cfg = copy.deepcopy(cfg)
    cfg["endpoint"] = "http://127.0.0.1:%d/api/alpha/decisions" % SERVER.server_address[1]
    cfg["timeout_s"] = 0.5
    return cfg


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ── the behaviour suite (run against the real module AND every mutant) ─────────

def suite(mod):
    """Returns a list of failure strings. Empty = every behaviour holds."""
    fails = []
    cfg = test_config(mod)
    os.environ["OPENROUTER_API_KEY"] = FAKE_KEY
    os.environ["JEV_GATE_LOG"] = log_path = os.path.join(TMP, "decisions-%d.jsonl" % time.monotonic_ns())

    def check(cond, msg):
        if not cond:
            fails.append(msg)

    def claude(cmd=None, event="PermissionRequest", tool="Bash", ti=None, **kw):
        ev = {"hook_event_name": event, "tool_name": tool, "cwd": "/home/appuser/git/proj",
              "tool_input": ti if ti is not None else {"command": cmd}}
        ev.update(kw)
        return mod.claude_hook(ev, cfg)

    allow_pr = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}

    # confident safe -> allow (both Claude events), request shape per the Decisions API
    reset(nouls(all=0.95))
    check(claude("ls src") == allow_pr, "safe Bash on PermissionRequest must allow")
    b = Mock.bodies[0]["body"] if Mock.bodies else {}
    check(b.get("model") == "typesafe/jev-1.13", "model must be typesafe/jev-1.13")
    check(isinstance(b.get("questions"), dict) and set(b["questions"]) == {"reversible"},
          "questions must be a MAP; no task -> only reversible is asked")
    check(all(q.get("type") == "noul" and "needs" not in q for q in b.get("questions", {}).values()),
          "questions are typed noul and carry no gate-internal keys")
    check(set(b.get("state", {})) == {"tool", "input", "project"}, "state must be minimal: tool/input/project")
    check(Mock.bodies and Mock.bodies[0]["auth"] == "Bearer " + FAKE_KEY, "bearer key from OPENROUTER_API_KEY")
    reset(nouls(all=0.95))
    out = claude("ls src", event="PreToolUse")
    check(out and out["hookSpecificOutput"].get("permissionDecision") == "allow", "PreToolUse shape must allow")
    reset(nouls(all=0.95))
    claude(ti={"command": "pytest -q", "description": "run the tests"})
    check(Mock.bodies and set(Mock.bodies[0]["body"]["questions"]) == {"reversible", "serves_task"}
          and Mock.bodies[0]["body"]["state"].get("task") == "run the tests", "a description is asked as the task")

    # threshold boundary (0.85 inclusive) and below
    reset(nouls(all=0.85))
    check(claude("ls") == allow_pr, "score == threshold must allow")
    reset(nouls(all=0.849))
    check(claude("ls") is None, "score just below threshold must defer")
    reset(lambda body: {"reversible": {"noul": 0.99}, "serves_task": {"noul": 0.40}})
    check(claude(ti={"command": "make", "description": "x"}) is None, "every asked question must clear")

    # never deny: confidently unsafe -> no output for claude
    reset(nouls(all=0.01))
    check(claude("ls") is None, "claude must never be told deny (unsafe -> defer)")

    # static never-auto-approve list: no Decisions call at all
    for cmd in ["git push origin main", "cd x && git push", "FOO=1 git push", "rm -rf build", "sudo ls",
                "echo $(cat x)", "bash -c 'ls'", "cat .env", "curl https://x", "python3 -c 'print(1)'",
                "/usr/bin/git reset --hard", "ls; sops -d secrets.yaml", "env rm -rf /"]:
        reset(nouls(all=0.99))
        check(claude(cmd) is None and not Mock.bodies, "risky command reached Jev or was allowed: " + cmd)
    for path in ["/p/.github/workflows/ci.yml", "/home/appuser/git/cloud-vault/A/x.md", "/p/src/secrets.yaml"]:
        reset(nouls(all=0.99))
        check(claude(tool="Write", ti={"file_path": path, "content": "x"}) is None and not Mock.bodies,
              "risky path reached Jev: " + path)
    reset(nouls(all=0.99))
    check(claude(tool="Edit", ti={"file_path": "/p/src/a.py", "old_string": "a", "new_string": "b"}) == allow_pr,
          "a plain in-project Edit is asked and allowed")

    # failure modes: all of them behave as if the gate did not exist
    for label, kw in [("http 500", dict(status=500, reply=nouls(all=0.99))),
                      ("malformed body", dict(raw=b"not json")),
                      ("prob out of range", dict(reply=nouls(all=1.5))),
                      ("prob is bool", dict(reply=nouls(all=True))),
                      ("missing answer", dict(reply={})),
                      ("answers not object", dict(raw=b'{"answers": [1]}')),
                      ("timeout", dict(reply=nouls(all=0.99), delay=1.2))]:
        reset(**kw)
        check(claude("ls") is None, "failure mode must defer: " + label)
    del os.environ["OPENROUTER_API_KEY"]
    reset(nouls(all=0.99))
    check(claude("ls") is None and not Mock.bodies, "no key -> no call, defer")
    os.environ["OPENROUTER_API_KEY"] = FAKE_KEY

    # oversized state is never sent truncated
    reset(nouls(all=0.99))
    check(claude(tool="Write", ti={"file_path": "/p/a.txt", "content": "x" * 20000}) is None and not Mock.bodies,
          "oversized state must defer without a call")

    # redaction: patterns + exact values of secret-named env vars
    os.environ["SOME_SERVICE_TOKEN"] = live = "liveValue-1234567890"
    reset(nouls(all=0.95))
    claude("echo ghp_" + "a" * 36 + " sk-or-v1-" + "b" * 40 + " API_KEY=hunter2hunter2 " + live)
    sent = json.dumps(Mock.bodies[0]["body"]) if Mock.bodies else ""
    for s in ["ghp_" + "a" * 36, "b" * 40, "hunter2hunter2", live, FAKE_KEY]:
        check(sent and s not in sent, "secret reached Jev state: " + s[:12])
    del os.environ["SOME_SERVICE_TOKEN"]

    # log: probabilities yes, state text never
    with open(log_path) as f:
        lines = [json.loads(l) for l in f]
    check(any(l.get("scores") and l.get("verdict") == "allow" for l in lines), "decisions logged with scores")
    logged = json.dumps(lines)
    check("hunter2" not in logged and "ls src" not in logged and FAKE_KEY not in logged, "log must not carry state")

    # goose: log mode passes everything; block mode blocks only confident-unsafe
    def goose(cmd, mode):
        cfg["uses"]["goose_pretool"]["on_unsafe"] = mode
        return mod.goose_hook({"event": "PreToolUse", "tool_name": "shell", "tool_input": {"command": cmd},
                               "working_dir": "/p"}, cfg)
    reset(nouls(all=0.02))
    check(goose("make deploy-ish", "log") is None, "goose on_unsafe=log must pass")
    reset(nouls(all=0.02))
    out = goose("make deploy-ish", "block")
    check(out and out.get("decision") == "block" and "reversible=0.02" in out.get("reason", ""),
          "goose on_unsafe=block must block confident-unsafe with a reason")
    reset(nouls(all=0.5))
    check(goose("make", "block") is None, "goose must pass when Jev is unsure")
    reset(nouls(all=0.99))
    check(goose("make", "block") is None, "goose must pass safe calls")
    reset(status=500)
    check(goose("make", "block") is None, "goose must pass on error")
    cfg["uses"]["goose_pretool"]["on_unsafe"] = "log"

    # hermes tool selection
    tools = [{"type": "function", "function": {"name": n, "description": "does " + n, "parameters": {}}}
             for n in ["terminal", "read_file", "web_search"]]
    req = {"model": "m", "messages": [{"role": "system", "content": "s"}, {"role": "user", "content": "read README"}],
           "tools": tools}
    reset(choice("read_file", 0.9))
    out = mod.select_tools(req, cfg, api_call_count=1)
    check(out and [t["function"]["name"] for t in out["tools"]] == ["read_file"], "confident pick -> that tool only")
    crit = Mock.bodies[0]["body"]["questions"]["tool"] if Mock.bodies else {}
    check(crit.get("type") == "choice" and set(crit.get("criteria", {})) == {"terminal", "read_file", "web_search", "none"},
          "choice over the tool names + none")
    check(Mock.bodies and Mock.bodies[0]["body"]["state"] == {"request": "read README"}, "hermes state = last user msg only")
    reset(choice("read_file", 0.6))
    check(mod.select_tools(req, cfg, api_call_count=1) is None, "low confidence -> all tools")
    reset(choice("read_file", 0.9))
    check(mod.select_tools(req, cfg, api_call_count=2) is None and not Mock.bodies, "only the first call of a turn")
    reset(choice("read_file", 0.9))
    check(mod.select_tools(req, cfg, api_call_count=1, api_mode="anthropic_messages") is None and not Mock.bodies,
          "unlisted api_mode untouched")
    reset(choice("none", 0.9))
    out = mod.select_tools(req, cfg, api_call_count=1)
    check(out is not None and "tools" not in out, "confident none -> no tools")
    traffic = dict(req, messages=req["messages"][:1] + [{"role": "assistant", "tool_calls": [{"id": "1"}]},
                                                       {"role": "tool", "content": "x"}] + req["messages"][1:])
    reset(choice("none", 0.9))
    check(mod.select_tools(traffic, cfg, api_call_count=1) is None, "none with tool history -> keep tools")
    reset(choice("bogus_tool", 0.99))
    check(mod.select_tools(req, cfg, api_call_count=1) is None, "a choice outside the offered set is an error")
    reset(status=500)
    check(mod.select_tools(req, cfg, api_call_count=1) is None, "error -> all tools (on_error=all_tools)")
    cfg["uses"]["hermes_tool_select"]["on_error"] = "no_tools"
    reset(status=500)
    out = mod.select_tools(req, cfg, api_call_count=1)
    check(out is not None and "tools" not in out, "on_error=no_tools is the fail-closed option")
    reset(choice("bogus_tool", 0.99))
    out = mod.select_tools(req, cfg, api_call_count=1)
    check(out is not None and "tools" not in out, "an out-of-set choice is an error under no_tools too")
    cfg["uses"]["hermes_tool_select"]["on_error"] = "all_tools"
    big = dict(req, tools=tools * 200)
    reset(choice("read_file", 0.9))
    check(mod.select_tools(big, cfg, api_call_count=1) is None and not Mock.bodies, "over max_options untouched")
    cfg["uses"]["hermes_tool_select"]["enabled"] = False
    reset(choice("read_file", 0.9))
    check(mod.select_tools(req, cfg, api_call_count=1) is None and not Mock.bodies, "disabled use makes no call")
    return fails


# ── mutation tests: each guard must be load-bearing ──────────────────────────

MUTANTS = [
    ("threshold inclusive", "all(s >= t for s", "all(s > t for s"),
    ("redaction skipped", '"input": redact(json.dumps(tool_input, ensure_ascii=False), cfg)',
     '"input": json.dumps(tool_input, ensure_ascii=False)'),
    ("env-value redaction skipped", 'text = text.replace(value, r["mask"])', "pass"),
    ("static list skipped", "if never_auto_approve(tool, tool_input, cfg):", "if False:"),
    ("unsafe becomes allow", 'if verdict != "allow":', 'if verdict == "defer":'),
    ("probability range unchecked", "if not scores or not all(_prob(s) for s in scores.values()):", "if not scores:"),
    ("timeout dropped", 'urllib.request.urlopen(req, timeout=cfg["timeout_s"])', "urllib.request.urlopen(req)"),
    ("oversize sent", 'if len(json.dumps(state)) > cfg["max_state_chars"]:', "if False:"),
    ("goose ignores on_unsafe", 'u.get("on_unsafe") == "block"', "True"),
    ("every call gated", '(u.get("first_call_only") and api_call_count != 1)', "(False)"),
    ("hermes ignores confidence", 'if p < u["threshold"]:', "if p < 0:"),
    ("none ignores tool history",
     'out = None if _has_tool_traffic(request.get("messages")) else _without_tools(request)',
     "out = _without_tools(request)"),
]


def mutation_tests():
    src = open(os.path.join(GATE_DIR, "jev_gate.py")).read()
    survived = []
    for label, old, new in MUTANTS:
        if src.count(old) != 1:
            survived.append("%s: mutation site not found exactly once (tester out of date)" % label)
            continue
        d = tempfile.mkdtemp(prefix="jev-mutant-", dir=TMP)
        shutil.copy(os.path.join(GATE_DIR, "jev-gate.json"), d)
        with open(os.path.join(d, "jev_gate.py"), "w") as f:
            f.write(src.replace(old, new))
        mutant = load(os.path.join(d, "jev_gate.py"), "jev_gate_mutant")
        if not suite(mutant):
            survived.append(label)
    return survived


# ── CLI entrypoint and host wiring ───────────────────────────────────────────

def cli_and_wiring():
    fails = []
    env = dict(os.environ, OPENROUTER_API_KEY=FAKE_KEY, JEV_GATE_LOG=os.path.join(TMP, "cli.jsonl"))
    cfgfile = os.path.join(TMP, "cli-config.json")
    mod = load(os.path.join(GATE_DIR, "jev_gate.py"), "jev_gate_cli")
    json.dump(test_config(mod), open(cfgfile, "w"))
    env["JEV_GATE_CONFIG"] = cfgfile
    run = lambda mode, stdin: subprocess.run([sys.executable, os.path.join(GATE_DIR, "jev_gate.py"), mode],
                                             input=stdin, capture_output=True, text=True, env=env, timeout=30)
    reset(nouls(all=0.95))
    r = run("claude", json.dumps({"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                  "tool_input": {"command": "ls"}, "cwd": "/p"}))
    if r.returncode or json.loads(r.stdout or "{}").get("hookSpecificOutput", {}).get("decision") != {"behavior": "allow"}:
        fails.append("CLI claude path did not allow a safe call: rc=%s out=%r" % (r.returncode, r.stdout))
    for mode, stdin in [("claude", "not json"), ("goose", ""), ("bogus", "{}")]:
        r = run(mode, stdin)
        if r.returncode or r.stdout.strip():
            fails.append("CLI %s with bad input must exit 0 silently (rc=%s out=%r)" % (mode, r.returncode, r.stdout))

    # hermes adapter registers llm_request middleware and tolerates an older hermes
    plugin = load(os.path.join(GATE_DIR, "__init__.py"), "jev_gate_plugin")
    seen = {}

    class Ctx:
        def register_middleware(self, kind, cb):
            seen[kind] = cb
    os.environ["JEV_GATE_CONFIG"] = cfgfile
    plugin.register(Ctx())
    plugin.register(object())  # no register_middleware: must not raise
    del os.environ["JEV_GATE_CONFIG"]
    if "llm_request" not in seen:
        fails.append("hermes plugin did not register llm_request middleware")
    else:
        reset(choice("b", 0.9))
        req = {"messages": [{"role": "user", "content": "q"}],
               "tools": [{"type": "function", "function": {"name": n}} for n in "ab"]}
        res = seen["llm_request"](request=req, api_call_count=1, api_mode="chat_completions", turn_id="t")
        if not res or [t["function"]["name"] for t in res["request"]["tools"]] != ["b"]:
            fails.append("hermes middleware did not return the narrowed request")

    # goose hooks.json: real goose 1.44 developer tool names, unanchored-regex safe
    hooks = json.load(open(os.path.join(GATE_DIR, "hooks", "hooks.json")))["hooks"]["PreToolUse"][0]
    rx = re.compile(hooks["matcher"])
    if not all(rx.search(n) for n in ["shell", "write", "edit"]) or any(rx.search(n) for n in ["tree", "cloud-infra-mcp__shell_x"]):
        fails.append("goose matcher must cover shell/write/edit only")
    if "$PLUGIN_ROOT/jev_gate.py\" goose" not in hooks["hooks"][0]["command"]:
        fails.append("goose hook must run the shared jev_gate.py from its plugin root")

    # each container actually ships and registers the gate
    def read(p):
        return open(os.path.join(ROOT, p)).read()
    s = json.load(open(os.path.join(ROOT, "user-ai_my-ai_claude-api/src/code/claude-config/settings.json")))
    pr = s.get("hooks", {}).get("PermissionRequest") or []
    if not any("jev_gate.py claude" in h.get("command", "") and re.fullmatch(e.get("matcher", ""), "Bash")
               for e in pr for h in e.get("hooks", [])):
        fails.append("claude settings.json lacks the PermissionRequest jev-gate hook")
    if "jev-gate" in s.get("permissions", {}).get("deny", []):
        fails.append("unexpected deny rule")
    for svc in ["user-ai_my-ai_claude-api", "user-ai_my-ai-api"]:
        if "../../_shared/jev-gate" not in read(svc + "/src/flake.nix"):
            fails.append(svc + ": flake extraFiles must carry ../../_shared/jev-gate")
        if not re.search(r"^COPY jev-gate/ /app/jev-gate/$", read(svc + "/src/code/Dockerfile"), re.M):
            fails.append(svc + ": Dockerfile must COPY jev-gate/ /app/jev-gate/")
    if "/app/jev-gate" not in read("user-ai_my-ai-api/src/code/start.sh") or ".agents/plugins" not in read("user-ai_my-ai-api/src/code/start.sh"):
        fails.append("goose start.sh must install /app/jev-gate as a ~/.agents/plugins plugin")
    if not re.search(r"^\s*enabled:\s*\[[^\]]*jev-gate", read("user-ai_hermes-agent/src/configs/config.yaml"), re.M):
        fails.append("hermes config.yaml must enable the jev-gate plugin")
    if "/opt/data/plugins/jev-gate" not in read("user-ai_hermes-agent/src/compose.nix"):
        fails.append("hermes compose must mount the plugin at /opt/data/plugins/jev-gate")
    if "_shared/jev-gate" not in read("user-ai_hermes-agent/src/flake.nix"):
        fails.append("hermes flake must emit the shared jev-gate files")
    for svc in ["user-ai_my-ai_claude-api", "user-ai_my-ai-api", "user-ai_hermes-agent"]:
        if not re.search(r"^OPENROUTER_API_KEY: ENC\[AES256_GCM", read(svc + "/src/secrets.yaml"), re.M):
            fails.append(svc + ": OPENROUTER_API_KEY must be a sops-encrypted key in src/secrets.yaml")
    return fails


def main():
    os.environ.pop("JEV_GATE_CONFIG", None)
    real = load(os.path.join(GATE_DIR, "jev_gate.py"), "jev_gate_real")
    fails = ["behaviour: " + f for f in suite(real)]
    survived = mutation_tests()
    fails += ["mutant SURVIVED (a guard is not tested): " + m for m in survived]
    fails += ["wiring: " + f for f in cli_and_wiring()]
    SERVER.shutdown()
    shutil.rmtree(TMP, ignore_errors=True)
    for f in fails:
        print("FAIL", f)
    print("jev-gate: %d/%d mutants killed, %d failures" % (len(MUTANTS) - len(survived), len(MUTANTS), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
