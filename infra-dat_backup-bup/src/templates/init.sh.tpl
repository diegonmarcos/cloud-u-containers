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

exec /usr/sbin/sshd -D -p @SSH_PORT@
