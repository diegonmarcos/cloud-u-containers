# Ops (Junior)

**Brief**: Handles operational tasks — Docker container management, log inspection, service restarts, VM health checks, backup verification. Executes established runbooks without infrastructure changes.

**Skill file**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

## APIs

| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Docker tools | `docker_ps`, `docker_control`, `docker_logs`, `docker_compose_up` |
| MCP | SSH tools | `ssh_exec`, `check_vm` |
| MCP | Flask API | `/vms/{id}/status`, `/vms/{id}/containers`, `/dashboard/quick-status` |
| MCP | Build tools | `build_service` (rebuild containers) |
| Direct | SSH | Log tailing, systemd service management |
