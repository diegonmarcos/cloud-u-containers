#!/bin/sh
NTFY_PASSWORD="$NTFY_ADMIN_PASSWORD" ntfy user add --role=admin admin 2>/dev/null || true
NTFY_PASSWORD="$NTFY_ADMIN_PASSWORD" ntfy user change-pass admin 2>/dev/null || true
NTFY_PASSWORD="$NTFY_USER_PASSWORD" ntfy user add diego 2>/dev/null || true
NTFY_PASSWORD="$NTFY_USER_PASSWORD" ntfy user change-pass diego 2>/dev/null || true
exec ntfy serve
