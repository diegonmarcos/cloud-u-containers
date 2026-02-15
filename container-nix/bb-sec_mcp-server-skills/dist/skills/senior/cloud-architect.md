# Cloud Architect Senior

**Brief**: Designs and manages the 4-VM cloud infrastructure — WireGuard mesh, Caddy reverse proxy, Authelia 2FA, 43 containerized services across OCI and GCP free tiers. Handles VM lifecycle, networking, DNS (Terraform), and cost optimization.

**Skill file**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

## APIs

| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Flask API | `/vms`, `/vms/{id}/status`, `/vms/{id}/start`, `/vms/{id}/stop`, `/vms/{id}/reset`, `/services`, `/services/{id}`, `/dashboard/summary`, `/wake/trigger`, `/wake/status`, `/providers`, `/domains` |
| MCP | OCI CLI | `oci compute instance action` (start/stop/reset) |
| MCP | gcloud CLI | `gcloud compute instances start/stop/reset` |
| MCP | Cloudflare | Terraform via `ba-clo_cloudflare/build.sh` |
| Direct | SSH | All 4 VMs (Docker, system commands, build.sh) |
| Direct | WireGuard | 10.0.0.0/24 mesh (inter-VM communication) |
