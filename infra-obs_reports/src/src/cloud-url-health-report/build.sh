#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="cloud-url-health-report"
. "$ROOT/../_crate_engine.sh"
engine_dispatch "$@"
