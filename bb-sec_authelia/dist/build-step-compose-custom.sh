#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Custom compose: pure docker CLI (no compose Go binary)
# Project: dist | Services: 2
set -e

# Ensure Docker daemon is running
if ! docker info >/dev/null 2>&1; then
  echo "[compose-custom] Docker not running — starting..."
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
  if ! docker info >/dev/null 2>&1; then
    echo "[compose-custom] ERROR: Docker failed to start" >&2
    exit 1
  fi
fi

# Create volumes
docker volume create authelia_data 2>/dev/null || true
docker volume create authelia_redis_data 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/authelia:latest" && docker pull ghcr.io/diegonmarcos/authelia:latest 2>/dev/null &
echo "  pull: ghcr.io/diegonmarcos/redis:latest" && docker pull ghcr.io/diegonmarcos/redis:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- authelia ---
docker rm -f authelia 2>/dev/null || true
docker run -d --name authelia --label com.docker.compose.project=authelia --label com.docker.compose.service=authelia --network host --dns 10.0.0.1 --dns 1.1.1.1 -v authelia_data:/data -v ./config/oidc_jwks.pem:/config/oidc_jwks.pem:ro --ulimit nofile=65536:65536 -e "AUTHELIA_JWT_SECRET=jwt-secret-change-me-in-production" -e "AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET==19=65536,t=3,p=4" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET=-sha512$$310000$$5pUaMU7Yxj1AeQRmfcDLnw.shJZFCtsapMyKUc1ORTwF.tBQymHk8QDtCZlmHRZSkPqasEgzDw" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET=-sha512$$310000.lKOz3poQI/8rPVJYBXA.SbtmHPI7fcU.nUQUN.K8lSVFbI5.bDMt4pXGnkRSdC8QsvP5chhVpm6A" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET==19=65536,t=3,p=4$$0Uz6fb37aI1VxqL9pHslugnN2QOxx7bMfe6tX36P0XY" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET=-sha512$$310000/lEmwAgHyuw$$9XHP1Awjt/Yima8SWTtyMlKFf7Kt532ckmQv8tzqPKQPNRkFmJoZ3u3iD/LQ4X.5oi9c/RlybVDtSzUF5BbkMA" -e "AUTHELIA_OIDC_CLIENT_CLI_SECRET=-sha512$$310000.2gcrNR2J5vBzAtgdTChYLg0/OsbWxyWgVAjhdPzMp9Hu6F/0Ti3O3/6MUCfKOT1j2yFTnNTcw" -e "AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET==19=65536,t=3,p=4$$1+oRP8nATTral+PYUKQT5MLGxZx6A6ZpJ6TkcCMLSco" -e "AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET=-sha512$$310000/yYc6YJ8MxxIg./jFXCRx6LkQ" -e "AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET==19=65536,t=3,p=4+TEu/GPedjzkg+hZSu08Ts/Zxq4kJTsJIPp7S+aio" -e "AUTHELIA_OIDC_CLIENT_DAGU_SECRET=-sha512$$310000.nh85m11PG2t1vD05G9SjNRqmC5vpHq34D0L1k3/8rtn51kCsqJP394/CoossUov2txbRv9BQhgjng" -e "AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET==19=65536,t=3,p=4$$4+QIc2ZzLfW7fG2m9HhdMg" -e "AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET=-sha512$$310000$$7YAzPafBo/cJ96o8RQfZOQ/irKu7OM8comRNbR8jHCXnWw1S9XKe1w3/pWSq/ohYr8bSSZEK9Tv.KaSVu20jtM0Tx0P3rAvGrfcgcI4.Q" -e "AUTHELIA_OIDC_CLIENT_MONITORING_SECRET=-sha512$$310000$$/BfaAvoPtwe5ITr3GkLmSA/QgHNMs.h/QLO3DsLLQIbG5h.5STxfAGfLBymwXMyoP3bhm3dD4LmJ1nAqF.EBieGgVyfDEENVtA" -e "AUTHELIA_OIDC_CLIENT_NOCODB_SECRET=-sha512$$310000.WA3IkLMsBhiViPXI1FSnevENY3OpJY89hTlBRVtQf3AoAIOQ" -e "AUTHELIA_OIDC_CLIENT_NPM_SECRET=-sha512$$310000$$15oXbGEaFNeZ6Bj2Ou3IFQ.0i5aWnrTc96ofsHnqQlPf.4qfFwbdzj7XEEFZY3hx81umSlwPRtYU0WKmZzZVcCIaM2.YuDzw" -e "AUTHELIA_OIDC_HMAC_SECRET=81109b30fa191d1467e5f52784211cd1d0fa1c226c553a2a88766192611aa75a" -e "AUTHELIA_REDIS_PASSWORD=authelia-redis-password-change-me" -e "AUTHELIA_SESSION_SECRET=authelia-secret-change-me-in-production" -e "AUTHELIA_SMTP_PASSWORD=ogeid2B@" -e "AUTHELIA_STORAGE_ENCRYPTION_KEY=storage-encryption-key-change-me-in-production" -e "AUTHELIA_USER_DIEGO_HASH==19=65536,t=3,p=4" -e "TZ=Europe/Madrid" --env-file .secrets --memory 134217728 --cpus 1 --memory-reservation 33554432 --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" --entrypoint "sh" ghcr.io/diegonmarcos/authelia:latest /config/init.sh
echo "  started: authelia"
# --- redis ---
docker rm -f authelia-redis 2>/dev/null || true
docker run -d --name authelia-redis --label com.docker.compose.project=redis --label com.docker.compose.service=redis --network host --dns 10.0.0.1 --dns 1.1.1.1 -v authelia_redis_data:/data --ulimit nofile=65536:65536 -e "AUTHELIA_JWT_SECRET=jwt-secret-change-me-in-production" -e "AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET==19=65536,t=3,p=4" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET=-sha512$$310000$$5pUaMU7Yxj1AeQRmfcDLnw.shJZFCtsapMyKUc1ORTwF.tBQymHk8QDtCZlmHRZSkPqasEgzDw" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET=-sha512$$310000.lKOz3poQI/8rPVJYBXA.SbtmHPI7fcU.nUQUN.K8lSVFbI5.bDMt4pXGnkRSdC8QsvP5chhVpm6A" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET==19=65536,t=3,p=4$$0Uz6fb37aI1VxqL9pHslugnN2QOxx7bMfe6tX36P0XY" -e "AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET=-sha512$$310000/lEmwAgHyuw$$9XHP1Awjt/Yima8SWTtyMlKFf7Kt532ckmQv8tzqPKQPNRkFmJoZ3u3iD/LQ4X.5oi9c/RlybVDtSzUF5BbkMA" -e "AUTHELIA_OIDC_CLIENT_CLI_SECRET=-sha512$$310000.2gcrNR2J5vBzAtgdTChYLg0/OsbWxyWgVAjhdPzMp9Hu6F/0Ti3O3/6MUCfKOT1j2yFTnNTcw" -e "AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET==19=65536,t=3,p=4$$1+oRP8nATTral+PYUKQT5MLGxZx6A6ZpJ6TkcCMLSco" -e "AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET=-sha512$$310000/yYc6YJ8MxxIg./jFXCRx6LkQ" -e "AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET==19=65536,t=3,p=4+TEu/GPedjzkg+hZSu08Ts/Zxq4kJTsJIPp7S+aio" -e "AUTHELIA_OIDC_CLIENT_DAGU_SECRET=-sha512$$310000.nh85m11PG2t1vD05G9SjNRqmC5vpHq34D0L1k3/8rtn51kCsqJP394/CoossUov2txbRv9BQhgjng" -e "AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET==19=65536,t=3,p=4$$4+QIc2ZzLfW7fG2m9HhdMg" -e "AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET=-sha512$$310000$$7YAzPafBo/cJ96o8RQfZOQ/irKu7OM8comRNbR8jHCXnWw1S9XKe1w3/pWSq/ohYr8bSSZEK9Tv.KaSVu20jtM0Tx0P3rAvGrfcgcI4.Q" -e "AUTHELIA_OIDC_CLIENT_MONITORING_SECRET=-sha512$$310000$$/BfaAvoPtwe5ITr3GkLmSA/QgHNMs.h/QLO3DsLLQIbG5h.5STxfAGfLBymwXMyoP3bhm3dD4LmJ1nAqF.EBieGgVyfDEENVtA" -e "AUTHELIA_OIDC_CLIENT_NOCODB_SECRET=-sha512$$310000.WA3IkLMsBhiViPXI1FSnevENY3OpJY89hTlBRVtQf3AoAIOQ" -e "AUTHELIA_OIDC_CLIENT_NPM_SECRET=-sha512$$310000$$15oXbGEaFNeZ6Bj2Ou3IFQ.0i5aWnrTc96ofsHnqQlPf.4qfFwbdzj7XEEFZY3hx81umSlwPRtYU0WKmZzZVcCIaM2.YuDzw" -e "AUTHELIA_OIDC_HMAC_SECRET=81109b30fa191d1467e5f52784211cd1d0fa1c226c553a2a88766192611aa75a" -e "AUTHELIA_REDIS_PASSWORD=authelia-redis-password-change-me" -e "AUTHELIA_SESSION_SECRET=authelia-secret-change-me-in-production" -e "AUTHELIA_SMTP_PASSWORD=ogeid2B@" -e "AUTHELIA_STORAGE_ENCRYPTION_KEY=storage-encryption-key-change-me-in-production" -e "AUTHELIA_USER_DIEGO_HASH==19=65536,t=3,p=4" --env-file .secrets --memory 50331648 --cpus 1 --memory-reservation 16777216 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/redis:latest sh -c "redis-server --port 6380 --requirepass $$AUTHELIA_REDIS_PASSWORD --appendonly yes --appendfsync everysec --save 900 1 --save 300 10"
echo "  started: authelia-redis"
