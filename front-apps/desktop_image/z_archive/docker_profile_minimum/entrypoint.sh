#!/bin/bash

# Container entry point
# GUI apps use host's X server via DISPLAY variable

exec "$@"
