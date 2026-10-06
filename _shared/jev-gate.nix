# jev-gate.nix — the ONE jev-gate package (#881).
#
# Until now every container copied _shared/jev-gate into its image by hand (my-ai-api, claude-api,
# hermes) and the desktop / termux flakes had no way to get it at all. This is the derivation they
# all consume:
#
#   pkgs.callPackage ./jev-gate.nix { }          # from a flake with pkgs in scope
#   import ../../_shared/jev-gate.nix { inherit pkgs; }
#
#   $out/bin/jev-gate                  the gate. Modes: claude | goose | goose-prompt (the agent hooks),
#                                      `decide --use <name>` ({state, questions} on stdin -> verdict
#                                      JSON), `serve` (the oci-apps sidecar, POST /decide/<use>)
#   $out/share/jev-gate/               the directory the hermes and goose plugins keep their layout
#                                      in: jev_gate.py, jev-gate.json, __init__.py, plugin.yaml, hooks/
#
# The config is $out/share/jev-gate/jev-gate.json unless JEV_GATE_CONFIG says otherwise (load_config
# already honours it), so one declaration serves every host. The key is read from OPENROUTER_API_KEY at
# run time; nothing secret is in the store.
{ pkgs }:

let
  share = pkgs.runCommand "jev-gate-share" { } ''
    mkdir -p $out/share/jev-gate
    cp -r ${./jev-gate}/. $out/share/jev-gate/
    rm -rf $out/share/jev-gate/__pycache__
  '';

  bin = pkgs.writers.writePython3Bin "jev-gate" { flakeIgnore = [ "E501" "E402" ]; } ''
    import os
    import sys

    share = "${share}/share/jev-gate"
    os.environ.setdefault("JEV_GATE_CONFIG", share + "/jev-gate.json")
    sys.path.insert(0, share)
    import jev_gate

    sys.exit(jev_gate.main(["jev-gate"] + sys.argv[1:]))
  '';
in
pkgs.symlinkJoin {
  name = "jev-gate";
  paths = [ bin share ];
  meta = {
    description = "Jev (TypeSafe's decision model on OpenRouter's Decisions API) pre-flight gate: agent hooks, `decide`, and the mesh sidecar";
    mainProgram = "jev-gate";
  };
}
