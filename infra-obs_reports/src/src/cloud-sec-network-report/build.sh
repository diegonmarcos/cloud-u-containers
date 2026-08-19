#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="cloud-sec-network"
. "$ROOT/../_crate_engine.sh"
engine_dispatch "$@"
