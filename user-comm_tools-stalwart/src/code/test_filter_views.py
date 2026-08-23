#!/usr/bin/env python3
"""Filter-view checks against the real rules data.

Guards the invariant that broke silently: the size views must PARTITION the
size axis -- every message lands in exactly one, boundaries included. Run:

    python3 test_filter_views.py
"""
import importlib.util
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
GENERAL = HERE.parent / "mail-rules-general.json"

# jmap-sorter.py isn't an importable module name; load it by path.
spec = importlib.util.spec_from_file_location("jmap_sorter", HERE / "jmap-sorter.py")
sorter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sorter)

rules = json.loads(GENERAL.read_text())
views = rules["filters"]["views"]
size_views = [v for v in views if str(v.get("predicate", {}).get("type", "")).startswith("size_")]
assert size_views, "no size views found -- data shape changed"

# Every boundary in the data, plus the points either side of it.
bounds = set()
for v in size_views:
    p = v["predicate"]
    for k in ("bytes", "min", "max"):
        if k in p:
            bounds.add(p[k])
probes = {0, 1, 10**9}
for b in sorted(bounds):
    probes |= {b - 1, b, b + 1}

failures = []
for size in sorted(probes):
    if size < 0:
        continue
    em = {"size": size}
    hits = [v["folder"] for v in size_views if sorter._email_matches(em, v["predicate"], None)]
    if len(hits) != 1:
        failures.append((size, hits))

for size, hits in failures:
    kind = "NO BUCKET" if not hits else f"{len(hits)} BUCKETS"
    print(f"FAIL size={size}: {kind} -> {hits}", file=sys.stderr)

if failures:
    print(f"\n{len(failures)} size(s) do not land in exactly one bucket", file=sys.stderr)
    sys.exit(1)

print(f"ok: {len(probes)} sizes each land in exactly 1 of {len(size_views)} size views")
print(f"    boundaries checked: {sorted(bounds)}")

# --- the static/volatile contract the sorter relies on --------------------
errs = []

for v in views:
    if "axis" not in v:
        errs.append(f"view {v['folder']!r} has no 'axis'")
    if "volatile" not in v:
        errs.append(f"view {v['folder']!r} has no 'volatile'")

axis = rules["filters"].get("partition_axis")
if not axis:
    errs.append("filters.partition_axis is unset -- the sorter would recompute "
                "static views on every message, every poll")
else:
    part = [v for v in views if v.get("axis") == axis]
    if not part:
        errs.append(f"partition_axis={axis!r} matches no view")
    # The sentinel only works if the partition axis is itself static: a volatile
    # bucket could empty out and make an already-computed message look new.
    for v in part:
        if v.get("volatile"):
            errs.append(f"partition view {v['folder']!r} is volatile -- "
                        "cannot be used as the static-computed sentinel")
    if {v["folder"] for v in part} != {v["folder"] for v in size_views}:
        errs.append(f"partition_axis={axis!r} views disagree with the size views "
                    "actually probed above")

for e in errs:
    print(f"FAIL {e}", file=sys.stderr)
if errs:
    sys.exit(1)

vol = [v["folder"] for v in views if v.get("volatile")]
print(f"ok: partition_axis={axis!r} is static and usable as sentinel")
print(f"    {len(vol)} volatile view(s) recomputed per poll, "
      f"{len(views) - len(vol)} static computed once: {vol}")
