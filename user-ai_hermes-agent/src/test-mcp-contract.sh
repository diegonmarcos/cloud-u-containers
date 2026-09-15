#!/usr/bin/env bash
# ============================================================================
# test-mcp-contract.sh — hermes-agent must offer cloud-infra-mcp and
# cloud-cgc-pub-mcp to its model (#346).
#
# Hermes reads mcp_servers from configs/config.yaml (bind-mounted read-only at
# /opt/data/config.yaml). Those entries are direct mesh endpoints written by
# hand, so they can drift from the fleet's own declaration of each server's
# address without anything failing — the defect #184 found in the claude
# runner's hand-written list. A wrong port does not error at deploy time: the
# gateway starts, the server never connects, and the agent reasons blind.
#
# Declaring a server is also not the same as offering it. Hermes filters tools
# per platform: a platform_toolsets list that names no MCP server inherits every
# enabled one, but `no_mcp` removes them all and naming one server makes the
# list an allowlist that silently drops the other (hermes_cli/tools_config.py
# _merge_mcp_servers, Hermes Agent v0.21.2).
#
#   static  (always)            — both servers declared and not disabled, not
#                                 narrowed out of any platform, and each URL
#                                 equals the fleet declaration (ip + container
#                                 port) when cloud-infra is checked out beside
#   live    (endpoint reachable) — each declared URL completes an MCP
#                                 initialize and lists tools
#
# Usage: src/test-mcp-contract.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INFRA="${CLOUD_INFRA_DIR:-$HERE/../../../cloud-infra}"

python3 - "$HERE/configs/config.yaml" "$INFRA/1_cloud-configs/dist" <<'PY'
import json, os, sys, urllib.request, yaml

config_path, dist_dir = sys.argv[1], sys.argv[2]
REQUIRED = ["cloud-infra-mcp", "cloud-cgc-pub-mcp"]
failed = False

def ok(message):
    print(f"  ok   {message}")

def bad(message):
    global failed
    failed = True
    print(f"  FAIL {message}")

config = yaml.safe_load(open(config_path))
servers = config.get("mcp_servers") or {}

print("== static: declaration ==")
for name in REQUIRED:
    entry = servers.get(name)
    if not entry:
        bad(f"{name}: not declared in mcp_servers")
    elif entry.get("enabled", True) is False:
        bad(f"{name}: declared but enabled: false")
    else:
        ok(f"{name}: declared -> {entry.get('url')}")

for platform, toolsets in (config.get("platform_toolsets") or {}).items():
    names = [str(toolset) for toolset in toolsets or []]
    listed = [name for name in names if name in servers]
    if "no_mcp" in names:
        bad(f"platform {platform}: no_mcp removes every MCP server")
    elif listed and set(REQUIRED) - set(listed):
        bad(f"platform {platform}: lists {listed}, an allowlist that drops {sorted(set(REQUIRED) - set(listed))}")
    else:
        ok(f"platform {platform}: inherits every enabled MCP server")

print("== static: URL matches the fleet declaration ==")
if not os.path.isdir(dist_dir):
    print(f"  (cloud-infra dist/ not checked out at {dist_dir} — skipping)")
else:
    for name in REQUIRED:
        declaration = json.load(open(os.path.join(dist_dir, f"build-{name}.json")))
        expected = f"http://{declaration['services'][name]['ip']}:{declaration['container']['port']}/mcp"
        actual = (servers.get(name) or {}).get("url")
        if actual == expected:
            ok(f"{name}: {actual}")
        else:
            bad(f"{name}: declared {actual}, fleet declares {expected}")

print("== live: MCP handshake against the declared URLs ==")
def post(url, body, session=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if session:
        headers["Mcp-Session-Id"] = session
    request = urllib.request.Request(url, json.dumps(body).encode(), headers)
    return urllib.request.urlopen(request, timeout=30)

def result_of(response):
    for line in response.read().decode().splitlines():
        line = line.removeprefix("data: ").strip()
        if line.startswith("{"):
            message = json.loads(line)
            if "result" in message:
                return message["result"]
    return {}

for name in REQUIRED:
    url = (servers.get(name) or {}).get("url")
    if not url:
        continue
    try:
        response = post(url, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "hermes-test-mcp-contract", "version": "1"}}})
    except OSError as error:
        print(f"  (live SKIPPED for {name}: {url} unreachable from here — {error})")
        continue
    session = response.headers.get("Mcp-Session-Id")
    result_of(response)
    if not session:
        bad(f"{name}: initialize returned no Mcp-Session-Id")
        continue
    post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, session).read()
    tools = result_of(post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, session)).get("tools", [])
    if tools:
        ok(f"{name}: handshake + {len(tools)} tools")
    else:
        bad(f"{name}: handshake succeeded but tools/list returned nothing")

print("FAIL" if failed else "PASS")
sys.exit(1 if failed else 0)
PY
