#!/usr/bin/env bash
# test-licence-inventory-guard.sh — #827: proves licence-inventory.py `check`
# fails on every kind of unrecorded subject (must-fail), stays green on changes
# that must not need a new entry (must-pass), and that the suite itself notices
# a broken guard (mutants: each a copy of the script with one discovery path or
# the verdict disabled — every one must turn this suite red).
#
# Runs on a throw-away fixture repository, never on the real tree, and touches
# no network (refresh --offline).
#
#   test-licence-inventory-guard.sh [path/to/licence-inventory.py]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
self="$here/$(basename "$0")"
default_inv="$here/licence-inventory.py"   # repo-specific default, set where installed
inv="${1:-$default_inv}"; inv="$(cd "$(dirname "$inv")" && pwd)/$(basename "$inv")"
[ -f "$inv" ] || { echo "no inventory script at $inv" >&2; exit 2; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

fixture() {
  rm -rf "$work/r"; mkdir -p "$work/r"; cd "$work/r"
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p licenses app/src fork/sub libs/x svc/src py rs tf
  cat > licenses/curated.json <<'J'
{"scan_skip_prefixes":["z_archive/"],"asset_extensions":[".so",".jar",".ttf"],"maven_repos":[],
 "maven_group_licences":{"androidx":{"licence":"Apache-2.0"}},
 "docker_licences":{"alpine":{"licence":"LicenseRef-OS-Distribution"}},
 "directories":{"app":{"licence":"LicenseRef-NoLicenseGranted"},"fork":{"licence":"MIT"},"svc":{"licence":"LicenseRef-NoLicenseGranted"},
                "py":{"licence":"LicenseRef-NoLicenseGranted"},"rs":{"licence":"LicenseRef-NoLicenseGranted"},"tf":{"licence":"LicenseRef-NoLicenseGranted"},
                "libs":{"licence":"LicenseRef-NoLicenseGranted"},"licenses":{"licence":"LicenseRef-NoLicenseGranted"}},"assets":{}}
J
  echo '{"modules":[{"id":"fork","path":"fork","upstream":"F","licence":"MIT","repo":"x","ref":""}]}' > licenses/upstreams.json
  printf 'dependencies {\n    implementation "androidx.core:core:1.0.0"\n}\n' > app/build.gradle
  echo '{"name":"app","dependencies":{"left-pad":"1.0.0","fork-internal":"workspace:*"}}' > app/package.json
  echo '{"name":"fork-internal"}' > fork/package.json
  printf '[package]\nname = "own"\n[dependencies]\nserde = "1.0"\nown-lib = { path = "../x" }\n' > rs/Cargo.toml
  printf 'module example.com/own\n\nrequire (\n\tgithub.com/pkg/errors v0.9.1\n)\n' > rs/go.mod
  printf 'requests==2.31.0\n-r other.txt\n' > py/requirements.txt
  printf '[project]\nname = "ownpy"\ndependencies = ["httpx>=0.27"]\n' > py/pyproject.toml
  printf '{\n  inputs = {\n    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";\n    self-lib.url = "path:./lib";\n  };\n  outputs = { self, nixpkgs }: { };\n}\n' > svc/flake.nix
  printf 'ARG BASE=alpine:3.20\nFROM ${BASE} AS build\nRUN apk add --no-cache curl\nFROM build\nFROM scratch\n' > svc/src/Dockerfile
  printf 'services:\n  app:\n    image: "redis:7-alpine"\n' > svc/docker-compose.yml
  echo '{"upstream_image":"node:24-alpine","containers":{"db":{"image":"postgres:16"}}}' > svc/build.json
  printf 'provider "registry.terraform.io/hashicorp/aws" {\n  version = "5.0.0"\n}\n' > tf/.terraform.lock.hcl
  echo MIT > fork/LICENSE; echo MIT > fork/sub/LICENSE.md
  echo bin > fork/lib.so; echo x > app/src/a.kt; echo x > libs/x/a.kt
  git add -A && git commit -qm base
  python3 "$inv" refresh . --offline 2>/dev/null
  git add -A && git commit -qm inv
}

expect() {  # expect <0|1> <label>
  local rc=0; python3 "$inv" check . >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2 (exit $rc, wanted $1)"; fail=1; fi
}

suite() {
fixture; expect 0 "baseline fixture is clean"

# ── must-fail: a subject with no inventory entry ──
fixture; printf 'dependencies {\n    implementation("com.example:new-lib:2.0")\n}\n' > libs/x/build.gradle; git add -A
expect 1 "new Maven coordinate in a build.gradle"
fixture; echo '{"name":"app","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.0","fork-internal":"workspace:*"}}' > app/package.json; git add -A
expect 1 "new npm dependency"
fixture; printf '[dev-dependencies]\ntokio = { version = "1", features = ["full"] }\n' >> rs/Cargo.toml; git add -A
expect 1 "new crate in a Cargo.toml table"
fixture; sed -i 's|^)|\tgolang.org/x/net v0.20.0\n)|' rs/go.mod; git add -A
expect 1 "new module in a go.mod require block"
fixture; echo 'flask>=3' >> py/requirements.txt; git add -A
expect 1 "new package in a requirements.txt"
fixture; sed -i 's|"httpx>=0.27"|"httpx>=0.27", "pydantic"|' py/pyproject.toml; git add -A
expect 1 "new dependency in a pyproject.toml"
fixture; sed -i 's|^  };|    hm.url = "github:nix-community/home-manager";\n  };|' svc/flake.nix; git add -A
expect 1 "new flake input"
fixture; printf 'FROM debian:12-slim\n' > libs/x/Dockerfile; git add -A
expect 1 "new Dockerfile base image"
fixture; printf '  db:\n    image: ghcr.io/x/y:1\n' >> svc/docker-compose.yml; git add -A
expect 1 "new compose image"
fixture; echo '{"upstream_image":"node:24-alpine","containers":{"db":{"image":"postgres:16"},"c":{"image":"valkey/valkey:8"}}}' > svc/build.json; git add -A
expect 1 "new build.json container image"
fixture; printf 'provider "registry.terraform.io/oracle/oci" {\n  version = "6.0.0"\n}\n' >> tf/.terraform.lock.hcl; git add -A
expect 1 "new Terraform provider"
fixture; mkdir -p libs/vendored; echo GPL > libs/vendored/COPYING; git add -A
expect 1 "new vendored directory carrying a licence file"
fixture; mkdir -p libs/fonts; echo OFL > libs/fonts/OPEN-SANS-LICENSE.txt; git add -A
expect 1 "new vendored directory carrying a prefixed licence file"
fixture; echo bin > libs/x/libfoo.so; git add -A
expect 1 "new native library binary"
fixture; mkdir -p newtop; echo x > newtop/a.txt; git add -A
expect 1 "new top-level directory"
fixture; python3 - <<'P'
import json; p="licenses/inventory.json"; d=json.load(open(p)); d["entries"].pop("docker:alpine"); json.dump(d,open(p,"w"))
P
expect 1 "inventory entry deleted"
fixture; python3 - <<'P'
import json; p="licenses/curated.json"; d=json.load(open(p)); d["directories"].pop("libs"); json.dump(d,open(p,"w"))
P
python3 "$inv" refresh . --offline 2>/dev/null
expect 1 "top-level directory with no curated licence (refreshed anyway)"

# ── must-pass: changes that must NOT need an entry ──
fixture; sed -i 's/core:1.0.0/core:1.1.0/; ' app/build.gradle; sed -i 's/serde = "1.0"/serde = "1.1"/' rs/Cargo.toml
sed -i 's/alpine:3.20/alpine:3.21/' svc/src/Dockerfile; sed -i 's/redis:7-alpine/redis:7.4-alpine@sha256:abc/' svc/docker-compose.yml; git add -A
expect 0 "version / tag / digest bumps of recorded dependencies"
fixture; mkdir -p fork/deeper; echo MIT > fork/deeper/LICENSE; git add -A
expect 0 "licence file inside a declared upstream module"
fixture; echo x > app/licence-guard.yml; echo x > app/check-license; git add -A
expect 0 "a file merely named like a licence is not a vendored directory"
fixture; printf 'FROM build AS again\nFROM scratch\n' >> svc/src/Dockerfile; git add -A
expect 0 "stage aliases and scratch are not images"
fixture; printf '[package]\nname = "x"\n[dependencies]\nown = { path = "../rs" }\nserde = { workspace = true }\n' > libs/x/Cargo.toml; git add -A
expect 0 "path, workspace and in-tree crates are own code"
}

if [ -n "${LICENCE_GUARD_MUTANT:-}" ]; then suite; exit $fail; fi
suite
[ "$fail" = 0 ] || { echo "suite FAILED against the real script"; exit 1; }

# ── mutants: the suite must go red against each broken copy of the guard ──
mutate() {  # mutate <label> <python-regex> <replacement>
  local m="$work/mutant.py"
  python3 - "$inv" "$m" "$2" "$3" <<'P'
import re, sys
s = open(sys.argv[1]).read()
t, n = re.subn(sys.argv[3], sys.argv[4], s, count=1, flags=re.M)
if n != 1: sys.exit(f"mutation did not apply: {sys.argv[3]}")
open(sys.argv[2], "w").write(t)
P
  if LICENCE_GUARD_MUTANT=1 bash "$self" "$m" >/dev/null 2>&1; then
    echo "FAIL mutant survived: $1"; fail=1
  else
    echo "ok   mutant killed: $1"
  fi
}
mutate "check always passes"         '^    if missing or bad:'                       '    if False:'
mutate "cargo discovery removed"     '^            cargo\(parsed\[f\], f, internal\["cargo"\], add\)' '            pass'
mutate "Dockerfile FROM ignored"     '^                if k:\n                    add\("docker:" \+ k, declared_in=f, version=ref, scope="base"\)' '                pass'
mutate "flake inputs ignored"        '^                if k:\n                    add\("flake:" \+ k'  '                if False:\n                    add("flake:" + k'
mutate "go.mod ignored"              '^        elif base == "go.mod":'               '        elif base == "go.mod.disabled":'
mutate "tag not stripped (bump red)" '^    if ":" in last\[-1\]:'                  '    if False:'
exit $fail
