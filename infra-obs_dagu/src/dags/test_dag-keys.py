#!/usr/bin/env python3
"""Guard: dagu rejects camelCase schema keys (HTTP 400 "has invalid keys:
continueOn; use snake_case keys"). Parses every src/dags/*.yaml and fails on any
camelCase key at DAG level or step level (recursively inside step mappings, but
not inside `env`, whose keys are user variable names).
Run: python3 src/dags/test_dag-keys.py   (exit 0 = pass)"""
import glob, os, re, sys
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
CAMEL = re.compile(r"^[a-z][a-z0-9_]*[A-Z]")
bad = []


def walk(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(k, str) and CAMEL.match(k):
                bad.append("%s: %s" % (path, k))
            if k not in ("env", "params"):
                walk(v, "%s.%s" % (path, k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, "%s[%d]" % (path, i))


files = sorted(glob.glob(os.path.join(HERE, "**", "*.yaml"), recursive=True))
for f in files:
    doc = yaml.safe_load(open(f))
    if isinstance(doc, dict):
        walk({k: v for k, v in doc.items() if k != "env"}, os.path.relpath(f, HERE))
print("checked %d DAG files" % len(files))
for b in bad:
    print("FAIL: camelCase key " + b)
print("FAILED" if bad else "PASS")
sys.exit(1 if bad else 0)
