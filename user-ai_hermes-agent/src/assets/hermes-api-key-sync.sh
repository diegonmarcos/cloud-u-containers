#!/bin/sh
# hermes-api-key-sync.sh — compose post_hook for hermes-agent.
#
# Makes the Hermes API server run with API_SERVER_KEY from sops
# (src/secrets.hermes-api.yaml -> .secrets env_file + .secrets.d/).
#
# Why a hook and not just the env var: Hermes loads $HERMES_HOME/.env (here
# /opt/data/.env, inside the hermes-agent-data volume) with override=True
# (hermes_cli/env_loader.py load_hermes_dotenv), and then clears "known keys"
# that are missing from that file. So whatever API_SERVER_KEY that .env holds
# beats the container environment, and deleting the line would unset the key.
# The only way for the declared value to win is to write it into that .env.
#
# Idempotent: rewrites the API_SERVER_KEY line only when it differs, and only
# then restarts the container. The value never touches a command line or a
# log: inside the container python reads it from its own environment (the
# env_file), on the host curl reads the Authorization header from stdin.
set -eu
cd "$(dirname "$0")/.."
SD=.secrets.d
C=cloud-agi-hermes
port=$(grep -o '"API_SERVER_PORT":"[0-9]*"' compose/docker-compose.yml | head -1 | grep -o '[0-9][0-9]*' || true)
[ -n "$port" ] || port=$(grep -o 'API_SERVER_PORT: *"*[0-9]*' compose/docker-compose.yml | head -1 | grep -o '[0-9][0-9]*$' || true)
[ -n "$port" ] || { echo "[hermes-key] cannot read API_SERVER_PORT from compose/docker-compose.yml"; exit 1; }
[ -s "$SD/API_SERVER_KEY" ] || { echo "[hermes-key] $SD/API_SERVER_KEY missing — secrets.hermes-api.yaml did not decrypt"; exit 1; }

i=0
until [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null || true)" = true ]; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "[hermes-key] $C not running after 300s"; exit 1; }
    sleep 5
done

result=$(docker exec -i "$C" /opt/hermes/.venv/bin/python3 - <<'PY'
import os, sys, tempfile
key = os.environ.get("API_SERVER_KEY", "")
if len(key) < 16:
    print("nokey"); sys.exit(0)
path = "/opt/data/.env"
lines = []
if os.path.exists(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().splitlines()
want = "API_SERVER_KEY=" + key
out, found = [], False
for ln in lines:
    s = ln.lstrip()
    if s.startswith("export "):
        s = s[7:].lstrip()
    if s.split("=", 1)[0].strip() == "API_SERVER_KEY":
        if not found:
            out.append(want)
        found = True
        continue
    out.append(ln)
if not found:
    out.append(want)
if out == lines:
    print("unchanged"); sys.exit(0)
st = os.stat(path) if os.path.exists(path) else None
fd, tmp = tempfile.mkstemp(dir="/opt/data", prefix=".env.")
with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write("\n".join(out) + "\n")
os.chmod(tmp, 0o600)
if st is not None:
    os.chown(tmp, st.st_uid, st.st_gid)
else:
    os.chown(tmp, 10001, 999)
os.replace(tmp, path)
print("changed")
PY
)
case "$result" in
    nokey)     echo "[hermes-key] API_SERVER_KEY is not in $C's environment (env_file .secrets)"; exit 1 ;;
    changed)   echo "[hermes-key] volume .env API_SERVER_KEY updated to the sops value; restarting $C"
               docker restart "$C" >/dev/null ;;
    unchanged) echo "[hermes-key] volume .env API_SERVER_KEY already matches the sops value" ;;
    *)         echo "[hermes-key] unexpected result from the in-container update"; exit 1 ;;
esac

# Verify: the API answers on loopback and accepts the declared key.
url="http://127.0.0.1:$port"
i=0
until [ "$(curl -s -m5 -o /dev/null -w '%{http_code}' "$url/health" || true)" = 200 ]; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "[hermes-key] $url/health not 200 after 300s"; exit 1; }
    sleep 5
done
code=$({ printf 'header = "Authorization: Bearer '; tr -d '\n' < "$SD/API_SERVER_KEY"; printf '"\n'; } \
       | curl -s -m15 -o /dev/null -w '%{http_code}' -K - "$url/health/detailed" || echo 000)
if [ "$code" != 200 ]; then
    echo "[hermes-key] $url/health/detailed with the sops key returned HTTP $code"
    exit 1
fi
echo "[hermes-key] Hermes API on :$port accepts the sops API_SERVER_KEY (verified)"
