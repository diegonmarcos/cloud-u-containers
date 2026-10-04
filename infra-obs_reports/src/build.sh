#!/bin/sh
# Thin shim → engine lives at reports/src/build.sh.
# Usage:   reports/build.sh [all|build|list|test-dists|manifest|<crate>|report<N>]
exec sh "$(cd "$(dirname "$0")" && pwd)/src/build.sh" "$@"
