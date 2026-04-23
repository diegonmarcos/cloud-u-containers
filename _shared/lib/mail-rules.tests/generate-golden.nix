# Emits the two expected outputs side-by-side, for golden capture.
#
# Usage:
#   nix-instantiate --eval --strict --json generate-golden.nix \
#     --arg generalPath  /abs/path/to/mail-rules-general.json \
#     --arg profilePath  /abs/path/to/mail-rules-profile-diego.json \
#     | jq -r '.sieve'           > golden/stalwart.sieve
#
#   nix-instantiate --eval --strict --json generate-golden.nix \
#     --arg generalPath  /abs/path/to/mail-rules-general.json \
#     --arg profilePath  /abs/path/to/mail-rules-profile-diego.json \
#     | jq '.maddy'              > golden/maddy.json
#
# Driven by run-tests.sh; do not edit goldens by hand.

{ generalPath, profilePath }:

let
  pkgs = import <nixpkgs> {};
  lib  = pkgs.lib;
  mr   = import ../mail-rules.nix { inherit lib; };
  merged = mr.loadAndMerge { inherit generalPath profilePath; };
in {
  sieve = mr.toSieve merged;
  maddy = mr.toMaddyJson merged;
}
