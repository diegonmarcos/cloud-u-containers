#!/bin/sh
# Guards against the bup-server crash loop: init.sh must never chmod a
# read-only bind-mounted authorized_keys. The key file has to be mounted
# outside /root/.ssh and copied into a writable path before chmod.
set -eu
cd "$(dirname "$0")"
fail=0
if grep -q 'authorized_keys:/root/.ssh/authorized_keys' compose.nix; then
    echo "FAIL: compose.nix mounts authorized_keys directly over /root/.ssh/authorized_keys"; fail=1
fi
grep -q '/configs/authorized_keys:ro' compose.nix \
    || { echo "FAIL: compose.nix must mount authorized_keys at /configs/authorized_keys:ro"; fail=1; }
grep -q '^cp /configs/authorized_keys /root/.ssh/authorized_keys' templates/init.sh.tpl \
    || { echo "FAIL: init.sh.tpl must cp /configs/authorized_keys into /root/.ssh"; fail=1; }
cpl=$(grep -n '^cp /configs/authorized_keys' templates/init.sh.tpl | head -1 | cut -d: -f1)
chl=$(grep -n 'chmod 600 /root/.ssh/authorized_keys' templates/init.sh.tpl | head -1 | cut -d: -f1)
[ -n "${cpl:-}" ] && [ -n "${chl:-}" ] && [ "$cpl" -lt "$chl" ] \
    || { echo "FAIL: cp must precede chmod 600"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: bup init copies authorized_keys before chmod"
exit "$fail"
