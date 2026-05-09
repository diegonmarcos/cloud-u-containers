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
{
  echo 'PermitRootLogin prohibit-password'
  # Bind sshd to WG IP only — keeps host-net listener off 0.0.0.0.
  # @LISTEN_ADDRESS@ comes from container.bind_host (cloud-data
  # resolveBindHost in 2_configs/src/engines/cloud-data-config-derive.ts).
  echo 'ListenAddress @LISTEN_ADDRESS@'
} >> /etc/ssh/sshd_config

exec /usr/sbin/sshd -D -p @SSH_PORT@
