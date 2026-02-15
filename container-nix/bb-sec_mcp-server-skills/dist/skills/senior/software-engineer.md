# Software Engineer Senior

**Brief**: Full-stack development across all repos — Rust API (gcp-proxy), Flask API, MCP server (TypeScript/Node), Nix flake configurations, Python tooling. Writes production code, reviews architecture, manages dependencies.

**Skill file**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

## APIs

| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Flask API | `/health`, `/config`, all CRUD endpoints |
| MCP | Rust API | `api.diegonmarcos.com:8080` (replacing Flask) |
| MCP | Repo tools | `read_file`, `search_repos`, `list_directory` across all 5 repos |
| MCP | Build tools | `build_service`, `build_all` |
| Direct | GitHub CLI | `gh pr`, `gh run`, `gh api` |
| Direct | npm/node | Package management, build toolchain |
| Direct | Cargo/rustc | Rust compilation (`--jobs 1` on micro VMs) |
