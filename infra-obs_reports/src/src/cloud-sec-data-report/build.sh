#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="cloud-sec-data"
SUPPORT_DIRS="yara-rules"
. "$ROOT/../_crate_engine.sh"
engine_dispatch "$@"
