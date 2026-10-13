#!/bin/sh
# Bup SSH backup receiver — alpine wrap-upstream entrypoint.
# Installs restic + openssh-server, prepares host keys + authorized_keys
# (mounted read-only at /configs via compose, copied to a writable path), then runs sshd in the foreground on
# port @SSH_PORT@.
set -eu

apk add --no-cache restic openssh-server

mkdir -p /backup/databases /root/.ssh
chmod 700 /root/.ssh
# Never chmod the read-only bind mount: copy it into the writable /root/.ssh.
cp /configs/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

ssh-keygen -A
grep -qxF 'PermitRootLogin prohibit-password' /etc/ssh/sshd_config \
    || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config

exec /usr/sbin/sshd -D -p @SSH_PORT@
