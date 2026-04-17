#!/bin/bash
set -e

# AUTO-GENERATED from cloud/config.json — DO NOT EDIT

apt-get update && apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev unzip wireguard-tools locales && rm -rf /var/lib/apt/lists/*
sed -i "s/^# *\(en_US.UTF-8\)/\1/" /etc/locale.gen && locale-gen

TF_VER=1.9.8
ARCH=$(dpkg --print-architecture)
curl -sL "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_${ARCH}.zip" -o /tmp/tf.zip
unzip -o /tmp/tf.zip -d /usr/local/bin/ && rm /tmp/tf.zip

RUST_VER=1.86.0
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VER}
ln -sf /root/.cargo/bin/* /usr/local/bin/
