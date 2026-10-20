#!/usr/bin/env python3
"""#882/#883 guard: "Jev has no opinion" == today's behaviour, per Dagu call site.
Runs the real step commands of the four DAGs that ask Jev (health_mail-ingest S2, health_docker-containers S5,
ops_deploy-pull-up S8, security_auth-events S10) under stub ssh/curl/date, and compares every ntfy publish
with jev-call-sites.golden.json (captured from the DAGs BEFORE Jev was wired). Cases: Jev disabled, sidecar
unreachable, no_key, gate_closed, malformed answer -> payloads identical to golden; an opinion -> only the
advice differs (and only where the DAG says so). Also: jev-ask.sh always exits 0.
Regenerate the golden only from a DAG revision without Jev:  python3 test_jev-call-sites.py --capture
Run: python3 src/dags/test_jev-call-sites.py   (needs yaml, jq, sh)"""
import json, os, shutil, stat, subprocess, sys, tempfile, yaml

HERE = os.path.dirname(os.path.abspath(__file__))
GOLD = os.path.join(HERE, "jev-call-sites.golden.json")
CASES = {  # dag -> (stub ssh output, ssh exit code)
    "health_mail-ingest": ("30", 0),
    "health_docker-containers": ("", 0),
    "ops_deploy-pull-up": ("", 1),
    "security_auth-events": ("1", 0),
}
LATEST = json.dumps({"containers": [{"name": "caddy", "health": "unhealthy", "status": "x"}]})


def stubs(d, answer):
    open(os.path.join(d, "curl"), "w").write("""#!/bin/sh
# records every ntfy publish; answers latest.json and the sidecar from env
url=""; data=""; hdr=""
while [ $# -gt 0 ]; do case "$1" in
  -H) hdr="$hdr|$2"; shift 2;; -d) data="$2"; shift 2;;
  -X|--max-time|-m) shift 2;; -s|-sf|-S) shift;; http*) url="$1"; shift;; *) shift;; esac; done
[ "$data" = "@-" ] && data=$(cat)
case "$url" in
  *:8199/*) printf '%s' "$STUB_LATEST";;
  *:3110/decide/*) [ -n "$STUB_ANSWER" ] && printf '%s' "$STUB_ANSWER"; [ "$STUB_ANSWER" = DOWN ] && exit 7;;
  *infra_jev*) ;;
  *) printf '%s\\n' "$url$hdr|$data" >> "$STUB_LOG";;
esac
exit 0
""")
    open(os.path.join(d, "ssh"), "w").write('#!/bin/sh\nprintf "%s" "$STUB_SSH"\nexit $STUB_SSH_RC\n')
    open(os.path.join(d, "date"), "w").write('#!/bin/sh\ncase "$*" in *%A*) echo Tuesday;; *%H*) echo 03;; *) /bin/date "$@";; esac\n')
    for n in ("curl", "ssh", "date"):
        os.chmod(os.path.join(d, n), 0o755)


def run_dag(name, answer):
    doc = yaml.safe_load(open(os.path.join(HERE, name + ".yaml")))
    env = {k: str(v) for e in doc.get("env", []) for k, v in e.items()}
    env["JEV_ASK"] = os.path.join(HERE, "lib", "jev-ask.sh")
    out = []
    for step in doc["steps"]:
        with tempfile.TemporaryDirectory() as d:
            stubs(d, answer)
            log = os.path.join(d, "log")
            e = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"], TMPDIR=d, STUB_LOG=log, STUB_LATEST=LATEST,
                     STUB_SSH=CASES[name][0], STUB_SSH_RC=str(CASES[name][1]), STUB_ANSWER=answer or "", **env)
            if answer is None:
                e["JEV_ASK_DISABLE"] = "1"
            subprocess.run(["sh", "-c", step["command"]], env=e, capture_output=True, timeout=60)
            out.append(open(log).read().splitlines() if os.path.exists(log) else [])
    return out


ANSWERS = {  # no opinion in every way the sidecar or the network can fail
    "jev disabled": None,
    "sidecar unreachable": "DOWN",
    "no_key": json.dumps({"ok": False, "use": "x", "reason": "no_key"}),
    "gate_closed": json.dumps({"ok": False, "use": "x", "reason": "gate_closed"}),
    "malformed": "<html>502</html>",
}


def main():
    if "--capture" in sys.argv:
        json.dump({n: run_dag(n, None) for n in CASES}, open(GOLD, "w"), indent=1)
        print("captured", GOLD)
        return 0
    gold = json.load(open(GOLD))
    fails = []
    for name in CASES:
        if not gold[name] or not any(gold[name]):
            fails.append("%s: golden has no publish at all" % name)
        for label, ans in ANSWERS.items():
            got = run_dag(name, ans)
            if got != gold[name]:
                fails.append("%s [%s]: payloads differ from today's\n  got  %r\n  want %r" % (name, label, got, gold[name]))
        op = {"ok": True, "use": "x", "results": {"q": {"type": "noul", "value": True, "p": 0.97, "confident": True},
                                                  "abnormal": {"type": "noul", "value": True, "p": 0.97, "confident": True},
                                                  "anomalous": {"type": "noul", "value": True, "p": 0.97, "confident": True}}}
        got = run_dag(name, json.dumps(op))
        if not any("Jev suggests" in l for step in got for l in step):
            fails.append("%s: an opinion never reaches the alert" % name)
    for ans in ANSWERS.values():  # the helper never fails its caller
        r = subprocess.run(["sh", os.path.join(HERE, "lib", "jev-ask.sh"), "mail_ingest_stall", "age_hours=3"],
                           env=dict(os.environ, JEV_SIDECAR_URL="http://127.0.0.1:9", JEV_ASK_TIMEOUT="1", NTFY_URL="http://127.0.0.1:9",
                                    TMPDIR=tempfile.mkdtemp()), capture_output=True)
        if r.returncode != 0 or r.stdout:
            fails.append("jev-ask.sh must exit 0 and print nothing when the sidecar is down")
        break
    for f in fails:
        print("FAIL", f)
    print("FAILED" if fails else "PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
