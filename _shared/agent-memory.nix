# ══════════════════════════════════════════════════════════════════
# agent-memory.nix — the agentic memory system, ONE declaration, EVERY agent.
#
# THE DEFECT (#556). The store already existed in the shared git tree and no
# agent was pointed at it: a-context-inject-memory.sh had been named
# "inject-memory" since it was written and injected only the principles
# checklist, so every oci-apps agent started with zero recall beside a full
# store it had mounted. The first pass at #556 fixed that — for ONE of the
# three runtimes. `runtime.memory` was declared in my-ai_claude-api's own
# build.json, so measured 2026-09-24 inside the running containers:
#
#   cloud-agi-claude  AGENT_MEMORY_DIR=/home/appuser/git/cloud-data-my-ai-memory/b_projects/home-diego
#   my-ai-api (goose) AGENT_GIT_TREE only — no AGENT_MEMORY_* at all
#   hermes-agent      AGENT_GIT_TREE only — no AGENT_MEMORY_* at all
#
# Two of the three agents still ran with zero recall, behind a ticket that read
# as done and a hook whose name said otherwise. A per-container declaration of
# a fleet-wide fact is what produced that, and it is the same shape #561
# removed from `agent.git_tree_mount` one file over: three containers, three
# answers, nothing checking.
#
# So the memory system is declared HERE, next to nothing else, and published by
# engine.nix to EVERY container that mounts the tree. A container that mounts
# the tree the store lives in and is not told where the store is cannot happen.
#
# LAYOUT IS LOAD-BEARING AND MEASURED — do not "tidy" it. Claude Code
# auto-loads the index PLUS every .md under SUBDIRECTORIES of the index's
# directory. A reorg that moved the entries to memory/<type>/ turned 129 entry
# files into auto-loaded imports and took session preload from ~4.5k to ~87k
# tokens (350,661 chars). The entries therefore sit OUTSIDE the index's
# directory, are read on demand, and the index's directory must never gain a
# subdirectory. That is why `entries` is a SIBLING name, not a child of the
# index: the two cannot be nested by editing one string.
#
# PURE ON PURPOSE — builtins only, no pkgs, no lib. This is what lets the
# tester EVALUATE it (and mutation-prove it) without a nixpkgs checkout, the
# same reason memory-ceiling.nix is written this way.
# ══════════════════════════════════════════════════════════════════

{ gitTreeMount        # the ONE canonical mount path, from engine.nix
, buildJson           # the service's parsed build.json — checked, not read from
, title               # service name, for the error message
}:

let
  # Where the store lives INSIDE the shared tree. Relative, and joined to the
  # mount below, so the absolute path cannot drift from the mount: they are one
  # binding apart, which is the property that failed when the path was retyped
  # per container.
  repoPath = "cloud-data-my-ai-memory/b_projects/home-diego";

  # The index sits in memory/ and the entries beside memory/, which is the
  # ~/.claude/projects/<slug>/ shape every device sees through its symlinks.
  # Pointers are written relative to memory/ (../memory-entries/<type>/<name>.md),
  # so they resolve the same way here and on the devices. The index used to be
  # read from ${repoPath}/MEMORY.md, where every such pointer resolved to a
  # directory that does not exist.
  dir     = "${gitTreeMount}/${repoPath}";
  index   = "memory/MEMORY.md";
  entries = "memory-entries";
  pointer = "../${entries}/<type>/<name>.md";
  types   = [ "feedback" "project" "reference" "user" ];

  typesStr = builtins.concatStringsSep " " types;

  # The briefing, also declared once. claude has a SessionStart hook and a Read
  # tool, so it gets the INDEX ITSELF (a-context-inject-memory.sh cats it).
  # goose and hermes have no session hook and no CLAUDE.md; their only
  # declarative context surface is a system-prompt string, so they get this
  # POINTER and read the index with the file/shell tools they do have.
  #
  # The pointer, never the index content: the index is ~170 lines of pointers
  # and pasting it into every request is the same bulk-load this layout exists
  # to prevent, one layer up.
  briefing = builtins.concatStringsSep "\n" [
    "## MEMORY"
    ""
    "You have persistent memory across sessions. It is an INDEX plus entries:"
    ""
    "  ${dir}/${index}"
    "      the index — one pointer line per entry. READ THIS FIRST, every session."
    "  ${dir}/${entries}/<type>/<name>.md"
    "      the entries, where <type> is one of: ${typesStr}"
    "      Pointers in the index are relative to the index's own directory:"
    "      `${pointer}` means the path above."
    "      Read one ONLY when it is relevant to the task in front of you."
    ""
    "NEVER bulk-read the entries directory. It is ~170 files; loading it costs"
    "more than the whole task. The index exists so that you do not have to."
    ""
    "To record something worth keeping:"
    "  1. Write the entry to ${entries}/<type>/<name>.md under the path above."
    "  2. Add ONE line to ${index}: `- [Title](${pointer}) — the hook`."
    "  3. NEVER put entry content in the index — it is paid for on every session."
    "  4. NEVER put anything else in memory/ — above all no subdirectory, and"
    "     never move the entries into one. Claude Code auto-loads every .md under a"
    "     subdirectory of the index's directory: that layout took session"
    "     preload from ~4.5k to ~87k tokens when it was tried, on every session"
    "     on the box, and it looks like nothing is wrong."
    "  5. Update an existing entry covering the same fact rather than adding a"
    "     near-duplicate."
    ""
    "An entry reflects what was true when it was written. If one names a file,"
    "flag or container, VERIFY it still exists before acting on it."
    ""
    "If the index above cannot be read, SAY SO: you are running WITHOUT recall,"
    "and that is a different thing from having nothing to remember."
  ];

  # Same shape, same reason, as engine.nix's git_tree_mount guard: a stale
  # `runtime.memory` left in a build.json would read as the live declaration
  # while the engine used this one. Not hypothetical — that field is where
  # these values came from, and leaving both would let claude's copy drift
  # away from what goose and hermes are told, which is the whole defect.
  guard =
    if ((buildJson.runtime or {}) ? memory)
    then throw ("${title}: runtime.memory is no longer per-container. The "
                + "agentic memory system is declared once in "
                + "_shared/agent-memory.nix and published to EVERY agent "
                + "container as AGENT_MEMORY_DIR / _INDEX / _ENTRIES / "
                + "_TYPES / _BRIEFING. Delete the field.")
    else null;

in
{
  inherit dir index entries pointer types briefing;

  # The env block engine.nix splices into every git-tree container. `seq` on the
  # guard, not a bare binding: Nix is lazy, so a throw nothing forces is
  # decoration — a check that passes whether or not the defect is present.
  env = {
    AGENT_MEMORY_DIR      = builtins.seq guard dir;
    AGENT_MEMORY_INDEX    = index;
    AGENT_MEMORY_ENTRIES  = entries;
    AGENT_MEMORY_TYPES    = typesStr;
    AGENT_MEMORY_BRIEFING = briefing;
  };

  # Some runtimes read their system-prompt extension from a name they own and
  # that we cannot change (hermes: HERMES_EPHEMERAL_SYSTEM_PROMPT, which
  # gateway/run_config_loaders.py resolves first and agent/turn_context.py
  # APPENDS to the base prompt at API-call time, so its tool instructions
  # survive). The container declares the env var NAME in build.json; the TEXT
  # stays here. A second copy of the text is how the three runtimes came to be
  # told three different things.
  aliasEnv = agentSpec:
    let a = agentSpec.memory_briefing_env or null;
    in if a == null then {} else { "${a}" = briefing; };
}
