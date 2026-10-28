#!/bin/sh
# Filebrowser header auth (#1147), declarative. Wraps the image ENTRYPOINT target (/init.sh) so the auth
# method is converged on every start instead of being a one-off `config set` typed by hand.
#   FB_PROXY_AUTH unset/empty : untouched (current login). Default, and the state until the edge Caddy
#                               that sends the identity header is deployed.
#   FB_PROXY_AUTH=true        : auth.method=proxy, header X-Forwarded-User (set by the hub caddy from
#                               proxy.primary.identity), and the mapped user exists.
#   FB_PROXY_AUTH=false       : explicit revert to the built-in json login.
# Break-glass: with proxy auth on, a request that does not come through the edge has no header and is
# refused; recover with FB_PROXY_AUTH=false (redeploy) - the mesh path does not bypass this.
# The mapped user is created with a random password that is never used by the proxy method.
set -u
DB="${FB_DATABASE:-/database/filebrowser.db}"
USER_NAME="${FB_PROXY_USER:-diego}"
case "${FB_PROXY_AUTH:-}" in
  true)
    if filebrowser config set -d "$DB" --auth.method=proxy --auth.header=X-Forwarded-User >/dev/null 2>&1; then
      echo "[fb-proxy-auth] auth.method=proxy"
      filebrowser users ls -d "$DB" 2>/dev/null | grep -qw "$USER_NAME" \
        || filebrowser users add "$USER_NAME" "$(head -c 24 /dev/urandom | base64)" --perm.admin -d "$DB" >/dev/null 2>&1 \
        || echo "[fb-proxy-auth] WARN: could not ensure user $USER_NAME" >&2
    else
      echo "[fb-proxy-auth] WARN: config set failed (database not initialised yet?), leaving auth as is" >&2
    fi
    ;;
  false)
    filebrowser config set -d "$DB" --auth.method=json >/dev/null 2>&1 \
      && echo "[fb-proxy-auth] auth.method=json" || echo "[fb-proxy-auth] WARN: revert failed" >&2
    ;;
esac
exec /init.sh "$@"
