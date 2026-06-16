#!/bin/sh
# Initialise ntfy users from secrets, then serve.
# User list is data-driven from src/users.json (rendered by flake.nix).
@USER_BLOCKS@
exec ntfy serve
