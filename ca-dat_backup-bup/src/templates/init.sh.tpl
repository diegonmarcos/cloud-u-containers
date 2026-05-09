#!/bin/sh
# Bup SSH backup receiver — alpine wrap-upstream entrypoint.
# Installs restic + openssh-server, prepares host keys + authorized_keys
# (mounted read-only via compose), then runs sshd in the foreground on
# port @SSH_PORT@.
set -eu

apk add --no-cache restic openssh-server

mkdir -p /backup/databases /root/.ssh
chmod 700 /root/.ssh
if [ -f /root/.ssh/authorized_keys ]; then
    chmod 600 /root/.ssh/authorized_keys
fi

ssh-keygen -A
grep -qxF 'PermitRootLogin prohibit-password' /etc/ssh/sshd_config \
    || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config

# Bind sshd to WG IP only — keeps host-net listener off 0.0.0.0.
# @LISTEN_ADDRESS@ comes from container.bind_host (cloud-data resolveBindHost
# in 2_configs/src/engines/cloud-data-config-derive.ts).
grep -qxF 'ListenAddress @LISTEN_ADDRESS@' /etc/ssh/sshd_config \
    || echo 'ListenAddress @LISTEN_ADDRESS@' >> /etc/ssh/sshd_config

exec /usr/sbin/sshd -D -p @SSH_PORT@
