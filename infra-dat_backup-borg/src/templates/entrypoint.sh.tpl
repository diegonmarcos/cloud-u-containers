#!/bin/sh
# entrypoint.sh — bootstrap borg + openssh-server on alpine.
# Runs inside the upstream alpine:3.19 container; configs mounted at /configs.
set -eu

apk add --no-cache borgbackup openssh-server

mkdir -p /backup/media /root/.ssh
chmod 700 /root/.ssh

cp /configs/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

ssh-keygen -A
echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config

exec /usr/sbin/sshd -D -p @SSH_PORT@
