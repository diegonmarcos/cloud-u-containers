#!/usr/bin/env bash
# ============================================================================
# bb-net_wireguard-mesh — declarative integrity tester
# ----------------------------------------------------------------------------
# Validates: build.json schema, file presence, TS/SCSS imports resolve,
# data wrapper integrity, snapshot data well-formed, hand-rolled SVG topology
# renders without throwing in node simulation.
# Read-only: never deploys, never modifies anything. Pure verification.
# ============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_JSON="$PROJ_DIR/build.json"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ wireguard-mesh tester  ($PROJ_DIR)"

# ── Phase 1 · file structure ─────────────────────────────────────────────
echo "▶ Phase 1 · structural"
[ -f "$BUILD_JSON" ]                              && ok "build.json present"          || nope "build.json missing"
[ -L "$PROJ_DIR/build.sh" ]                       && ok "build.sh symlinked to engine" || nope "build.sh symlink missing"
[ ! -f "$PROJ_DIR/secrets.yaml" ]                 && ok "no secrets.yaml (read-only static panel — pattern matches filebrowser/etherpad)" || nope "secrets.yaml present — read-only panels should omit it (sops pre-commit hook blocks unencrypted)"
[ -f "$PROJ_DIR/0.spec/README.md" ]               && ok "0.spec/README.md present"     || nope "0.spec missing"

for f in src/index.html src/Dockerfile src/nginx.conf src/compose.nix src/flake.nix \
         src/data/mesh.json src/scss/main.scss src/typescript/main.ts \
         tsconfig.json package.json; do
  [ -f "$PROJ_DIR/$f" ] && ok "$f" || nope "$f missing"
done

# ── Phase 2 · build.json schema ──────────────────────────────────────────
echo "▶ Phase 2 · build.json schema"
for k in name description deploy.host proxy.primary.domain proxy.primary.auth ports.app containers.app data_sources data_outputs; do
  v=$(jq -r "$([ "${k:0:1}" = "." ] && echo "$k" || echo ".$k")" "$BUILD_JSON" 2>/dev/null || true)
  [ -n "$v" ] && [ "$v" != "null" ] && ok "build.json.$k = $v" || nope "build.json.$k missing"
done
auth=$(jq -r '.proxy.primary.auth' "$BUILD_JSON")
[ "$auth" = "two_factor" ] && ok "auth = two_factor (Authelia-walled)" || nope "auth=$auth (expected two_factor)"
mem=$(jq -r '.containers.app.resources.mem_limit' "$BUILD_JSON")
[ "$mem" = "32m" ] && ok "mem_limit = 32m"      || nope "mem_limit=$mem (expected 32m)"
ro=$(jq -r '.containers.app.read_only' "$BUILD_JSON")
[ "$ro" = "true" ] && ok "container is read_only"   || nope "read_only=$ro"

# ── Phase 3 · static bundle builds ───────────────────────────────────────
echo "▶ Phase 3 · static bundle"
( cd "$PROJ_DIR" && npm run build >/tmp/wg-mesh-build.log 2>&1 ) \
  && ok "npm run build → exit 0" \
  || { nope "npm run build failed"; tail -10 /tmp/wg-mesh-build.log; exit 1; }

for f in dist/index.html dist/style.css dist/script.js dist/data-mesh.json.js; do
  if [ -s "$PROJ_DIR/$f" ]; then ok "$f ($(stat -c%s "$PROJ_DIR/$f") bytes)"
  else nope "$f missing or empty"; fi
done

# ── Phase 4 · TypeScript strict-mode ─────────────────────────────────────
echo "▶ Phase 4 · TypeScript strict"
( cd "$PROJ_DIR" && npx tsc --noEmit ) >/tmp/wg-mesh-tsc.log 2>&1 \
  && ok "tsc --noEmit clean" \
  || { nope "tsc reported errors"; head -20 /tmp/wg-mesh-tsc.log; }

# ── Phase 5 · data wrapper integrity ─────────────────────────────────────
echo "▶ Phase 5 · PORTAL_DATA wrapper"
WRAPPER="$PROJ_DIR/dist/data-mesh.json.js"
grep -q 'PORTAL_DATA' "$WRAPPER"           && ok "wrapper sets PORTAL_DATA"    || nope "wrapper missing PORTAL_DATA"
grep -q "'mesh'\|\"mesh\"" "$WRAPPER"     && ok "wrapper key is 'mesh'"        || nope "wrapper key missing"

# ── Phase 6 · snapshot data shape ────────────────────────────────────────
echo "▶ Phase 6 · snapshot schema"
SNAP="$PROJ_DIR/src/data/mesh.json"
for k in _meta nodes peers transports routes health; do
  jq -e "has(\"$k\")" "$SNAP" >/dev/null && ok "snapshot has .$k" || nope "snapshot missing .$k"
done
schema=$(jq -r '._meta.schema' "$SNAP")
[ "$schema" = "wg-mesh/v1" ] && ok "schema = $schema" || nope "schema=$schema (expected wg-mesh/v1)"

n_nodes=$(jq '.nodes | length' "$SNAP")
n_peers=$(jq '.peers | length' "$SNAP")
n_trans=$(jq '.transports | length' "$SNAP")
[ "$n_nodes" -gt 0 ] && ok "$n_nodes nodes"           || nope "no nodes"
[ "$n_peers" -gt 0 ] && ok "$n_peers peers"           || nope "no peers"
[ "$n_trans" -gt 0 ] && ok "$n_trans transports"      || nope "no transports"

# Each node has required fields
bad_nodes=$(jq '[.nodes[] | select((.name//"")=="" or (.role//"")=="" or (.wg_ip//"")=="")] | length' "$SNAP")
[ "$bad_nodes" = 0 ] && ok "every node has name+role+wg_ip" || nope "$bad_nodes nodes missing required fields"

# Roles are valid enum
bad_roles=$(jq '[.nodes[] | select(.role|IN("hub","spoke","client")|not)] | length' "$SNAP")
[ "$bad_roles" = 0 ] && ok "all roles ∈ {hub, spoke, client}" || nope "$bad_roles invalid roles"

# Peers reference existing nodes (bind peer to $p so .from/.to don't re-bind to $n's array context)
bad_peers=$(jq -r '
  [.nodes[].name] as $n
  | [.peers[] | . as $p | select(($n | index($p.from)) == null or ($n | index($p.to)) == null)] | length
' "$SNAP")
[ "$bad_peers" = 0 ] && ok "all peer edges reference existing nodes" || nope "$bad_peers peers reference unknown nodes"

# ── Phase 7 · render simulation (jsdom-free, hand-rolled mock) ──────────
echo "▶ Phase 7 · render simulation"
cat > /tmp/wg-mesh-sim.cjs <<'EOF'
const fs = require('node:fs');
const path = '/home/diego/git/cloud-infra/a_solutions/bb-net_wireguard-mesh';

// Minimal DOM shim
const elemMap = new Map();
function makeEl(tag) {
  const el = {
    tagName: tag, children: [], childNodes: [], childElementCount: 0,
    style: {}, dataset: {}, attributes: {},
    appendChild(c) { this.children.push(c); this.childElementCount++; return c; },
    setAttribute(k, v) { this.attributes[k] = v; if (k === 'id') elemMap.set(v, this); },
    getAttribute(k) { return this.attributes[k]; },
    addEventListener() {}, removeEventListener() {},
    querySelector: () => null, querySelectorAll: () => [],
    set innerHTML(v) {
      this._innerHTML = v;
      const re = /id="([^"]+)"/g; let m;
      while ((m = re.exec(v))) {
        const child = makeEl('div'); child.setAttribute('id', m[1]); this.children.push(child);
      }
    },
    get innerHTML() { return this._innerHTML || ''; },
    closest: () => null, matches: () => false, contains: () => false,
  };
  return el;
}
const app = makeEl('div'); app.setAttribute('id', 'app');
globalThis.document = {
  readyState: 'complete', getElementById: id => elemMap.get(id) || null,
  createElement: tag => makeEl(tag), addEventListener() {},
  body: app, head: makeEl('head'),
};
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.location = { hash: '', pathname: '/', href: 'https://mesh.diegonmarcos.com/' };
elemMap.set('app', app);

// Load wrapper + main
eval(fs.readFileSync(path + '/dist/data-mesh.json.js', 'utf8'));
console.log('PORTAL_DATA keys:', Object.keys(globalThis.PORTAL_DATA || {}));
try {
  eval(fs.readFileSync(path + '/dist/script.js', 'utf8'));
  console.log('script.js executed; #app children:', app.children.length);
  console.log('shell rendered:', app.innerHTML.includes('app__brand') ? 'yes' : 'no');
} catch (e) {
  console.error('script.js threw:', e.message);
  process.exit(2);
}
EOF
node /tmp/wg-mesh-sim.cjs >/tmp/wg-mesh-sim.log 2>&1 \
  && ok "script.js evaluates without throw" \
  || { nope "script.js threw in simulation"; cat /tmp/wg-mesh-sim.log; }
grep -q 'shell rendered: yes' /tmp/wg-mesh-sim.log \
  && ok "shell rendered (#app populated)" \
  || nope "shell did not render"

echo
if [ "$fail" = 0 ]; then
  printf '▶ \033[32m%d passed, 0 failed\033[0m\n' "$pass"
  exit 0
else
  printf '▶ \033[31m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
