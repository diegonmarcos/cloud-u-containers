#!/usr/bin/env bash
# test-vault-mtls.sh — behavioural test of the vault.diegonmarcos.com mTLS gate (#1117/#1137).
#
# Takes the `tls { client_auth ... }` block and the `@not_wg { ... }` matcher EXACTLY as rendered into
# the vault vhost of dist/configs/Caddyfile, drops them into a throwaway Caddy (same version as prod)
# with a throwaway CA, and proves the seven cases of the design:
#   a) off-mesh, no cert            -> 403
#   b) off-mesh, valid cert         -> 200 from upstream
#   c) cert signed by another CA    -> TLS handshake fails
#   d) expired cert                 -> TLS handshake fails
#   e) mesh source, no cert         -> 200
#   f) valid cert from a source that is neither mesh nor allow-listed (the "blocked country" stand-in;
#      this Caddy has no country gate, the only source gate is @not_wg) -> 200, i.e. the cert wins
#   g) WebSocket upgrade (/notifications/hub) with a cert -> 101 through the proxy
# plus guards: one vault URL only (no vault.mesh vhost), and no CA PRIVATE key is in the repo.
# "Mesh" is simulated as source 127.0.0.1, "off-mesh" as source 127.0.0.2 (the rendered CIDR list is substituted).
# The CA used here is generated in a temp dir; it is NOT the fleet CA.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CADDYFILE="${CADDYFILE:-$ROOT/dist/configs/Caddyfile}"
CADDY_VERSION="${CADDY_VERSION:-2.11.2}"
FAIL=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then ok "$1 (got $2)"; else bad "$1 (want $3, got $2)"; fi; }

# ── static guards (no caddy needed) ─────────────────────────────────────────
echo "== static"
[ -f "$CADDYFILE" ] || { echo "SKIP: $CADDYFILE not rendered yet"; exit 0; }
# A vhost starts at "  <dns.name> {" and runs to the next such line (the rendered output is not reliably indented).
site() { awk -v h="$1" 'BEGIN{re="^  [A-Za-z0-9*-]+(\\.[A-Za-z0-9*-]+)+( *, *[^ ]+)* \\{$"} p && $0 ~ re {exit} $0 ~ "^  "h" \\{" {p=1} p {print}' "$CADDYFILE"; }
VAULT="$(site vault.diegonmarcos.com)"
if [ -z "$VAULT" ]; then bad "vault.diegonmarcos.com vhost present"; exit 1; fi
if echo "$VAULT" | grep -q "mode verify_if_given"; then ok "vault vhost uses client_auth verify_if_given"
else
  # Until the fleet CA cert is committed (vault-mtls-issue workflow) the route stays strictly mesh-only.
  echo "SKIP: vault vhost has no client_auth yet (src/inputs/vault-client-ca.pem absent), mesh-only"; exit 0
fi
if site vault.mesh.diegonmarcos.com | grep -q .; then bad "no vault.mesh vhost (owner: ONE vault URL)"; else ok "no vault.mesh vhost (one URL: vault.diegonmarcos.com)"; fi
if grep -q "vaultwarden\.app" "$CADDYFILE"; then bad "no vaultwarden.app mapping left in Caddyfile"; else ok "no vaultwarden.app mapping left in Caddyfile"; fi
if grep -rIl -- "-----BEGIN [A-Z ]*PRIVATE KEY-----" "$ROOT" 2>/dev/null | grep -v "/test/" | grep -q .; then bad "no private key block in this tree"; else ok "no private key block in this tree"; fi

# ── dynamic ─────────────────────────────────────────────────────────────────
CADDY="$(command -v caddy || true)"
T="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
if [ -z "$CADDY" ] || ! "$CADDY" version | grep -q "v$CADDY_VERSION"; then
  curl -fsSL -m 120 -o "$T/c.tgz" "https://github.com/caddyserver/caddy/releases/download/v$CADDY_VERSION/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf "$T/c.tgz" -C "$T" caddy && CADDY="$T/caddy"
fi
[ -x "${CADDY:-/nonexistent}" ] || { echo "SKIP dynamic: no caddy v$CADDY_VERSION available"; exit "$FAIL"; }
export NO_PROXY="*" no_proxy="*"  # loopback only: never go through an agent/egress proxy
echo "== dynamic ($("$CADDY" version | cut -d' ' -f1))"

cd "$T" || exit 1
mkca() { openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null
         openssl req -new -x509 -key "$1.key" -subj "/CN=$1" -days 3 -out "$1.pem" 2>/dev/null; }
mkleaf() { # name ca [startdate enddate]
  openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null
  openssl req -new -key "$1.key" -subj "/CN=$1" -out "$1.csr" 2>/dev/null
  printf '[ca]\ndefault_ca=c\n[c]\ndatabase=idx\nnew_certs_dir=.\nserial=ser\ndefault_md=sha256\npolicy=p\ncopy_extensions=none\nx509_extensions=x\n[p]\ncommonName=supplied\n[x]\nextendedKeyUsage=clientAuth\n' > ca.cnf
  : > idx; echo 01 > ser
  if [ $# -ge 4 ]; then S="-startdate $3 -enddate $4"; else S="-days 2"; fi
  # shellcheck disable=SC2086
  openssl ca -batch -config ca.cnf -cert "$2.pem" -keyfile "$2.key" -in "$1.csr" -out "$1.pem" $S -notext 2>/dev/null
  rm -f idx* ser* 01.pem 02.pem
}
mkca fleet; mkca other
mkleaf good fleet; mkleaf wrongca other; mkleaf expired fleet 20240101000000Z 20240102000000Z
DER="$(grep -v -- '-----' fleet.pem | tr -d '\n')"

# the rendered tls block with the throwaway CA, the rendered matcher with the simulated mesh CIDRs
TLSB="$(echo "$VAULT" | awk '/^ *tls \{/ {d=0; p=1} p {print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); d+=n-m; if (d==0) exit}' | sed -E "s#trust_der .*#trust_der $DER#")"
MATCH="$(echo "$VAULT" | awk '/^ *@not_wg \{/ {p=1} p {print} p && /^ *\}$/ {exit}' | sed -E 's#not remote_ip [^ ]+( [^ ]+)*$#not remote_ip 127.0.0.1/32#')"
ERRL="$(echo "$VAULT" | grep -E '^ *error @not_wg "Forbidden" 403$' | head -1)"
[ -n "$ERRL" ] || bad "rendered vault vhost carries the 403 error line for @not_wg"
[ -n "$TLSB" ] && [ -n "$MATCH" ] || { bad "extract tls block and @not_wg matcher from the rendered vault vhost"; exit 1; }

python3 - 18080 <<'PY' &
import socket, sys, threading
def h(c):
    d = c.recv(4096)
    if b"upgrade: websocket" in d.lower():
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"); import time; time.sleep(3)
    else:
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    c.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
PY
cat > Caddyfile <<EOF
{
  admin off
  local_certs
  auto_https disable_redirects
  https_port 18443
  http_port 18081
  order error before handle
}
vault.test:18443 {
  bind 127.0.0.1
$TLSB
$MATCH
$ERRL
  handle {
    reverse_proxy 127.0.0.1:18080
  }
}
EOF
"$CADDY" run --config Caddyfile --adapter caddyfile > caddy.log 2>&1 &
for _ in $(seq 1 30); do curl -sk -m 1 -o /dev/null --resolve vault.test:18443:127.0.0.1 https://vault.test:18443/ && break; sleep 0.5; done

grep -iE "error|fatal" caddy.log | head -5 | cut -c1-300
OFF=127.0.0.2; MESHIP=127.0.0.1
req() { # source-ip [curl args...] -> http code, or "000" on handshake failure
  local src="$1"; shift
  curl -sk -m 4 -o /dev/null -w '%{http_code}' --interface "$src" --resolve vault.test:18443:127.0.0.1 "$@" https://vault.test:18443/alive 2>/dev/null || true
}
wsreq() { local src="$1"; shift
  curl -sk --http1.1 -m 3 -o /dev/null -w '%{http_code}' --interface "$src" --resolve vault.test:18443:127.0.0.1 "$@" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Key: dGVzdA==' -H 'Sec-WebSocket-Version: 13' https://vault.test:18443/notifications/hub 2>/dev/null || true; }
C="--cert good.pem --key good.key"
check "a) off-mesh, no cert -> 403"                 "$(req $OFF)" 403
check "b) off-mesh, valid cert -> 200"              "$(req $OFF $C)" 200
check "c) cert from another CA -> handshake fails"  "$(req $OFF --cert wrongca.pem --key wrongca.key)" 000
check "d) expired cert -> handshake fails"          "$(req $OFF --cert expired.pem --key expired.key)" 000
check "e) mesh source, no cert -> 200"              "$(req $MESHIP)" 200
check "f) valid cert, non-mesh non-allow-listed source -> 200 (cert wins)" "$(req $OFF $C)" 200
check "g) websocket upgrade with cert -> 101"       "$(wsreq $OFF $C)" 101
check "h) off-mesh, no cert, websocket -> 403"      "$(wsreq $OFF)" 403

[ "$FAIL" = 0 ] || tail -n 8 "$T/caddy.log" | cut -c1-300
[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$FAIL"
