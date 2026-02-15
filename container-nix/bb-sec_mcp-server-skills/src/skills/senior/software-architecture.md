# Software Architecture Senior

**Brief**: System design and Nix flake architecture — repo structure, module organization, build.sh engine design, flake composition (NixOS host, home-manager desktop/termux, cloud home-manager). Defines project archetypes and enforces the Nix Way.

**Skill file**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

## APIs

| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Repo tools | `read_file`, `search_repos`, `list_directory` (all repos) |
| MCP | Flask API | `/config`, `/cloud_control/infrastructure` |
| Direct | Nix CLI | `nix flake show`, `nix flake metadata` (via build.sh only) |
| Direct | Git | Cross-repo structure analysis |
