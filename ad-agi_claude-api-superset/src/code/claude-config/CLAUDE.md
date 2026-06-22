# Diego's Master Context for Claude Agents

```
  ─────────────────────
  ───────────████████──     NO DINOSAUR SYNTAX!
  ──────────███▄███████
  ──────────███████████     Use modern Compose v2, current APIs,
  ──────────███████████     latest Nix patterns. If you catch
  ──────────██████─────     yourself writing deprecated syntax,
  ──────────█████████──     STOP and look up the modern way.
  █───────███████──────
  ██────████████████───     deprecated = extinct
  ███──██████████──█───
  ███████████████──────
  ███████████████──────
  ─█████████████───────
  ──███████████────────
  ────████████─────────
  ─────███──██─────────
  ─────██────█─────────
  ─────█─────█─────────
  ─────██────██────────
  ─────────────────────
```

> **Owner**: Diego Nepomuceno Marcos
> **System**: NixOS (Surface Pro 8) + Kubuntu (dual-boot)
> **Git Root**: `/home/diego/git`
> **Auto-generated**: 2026-04-29 from cloud-data (5 VMs, 34 services with domains)

---

## Table of Contents

### STACK
- [A. UNIX (NixOS & System Configuration)](#section-a-unix-nixos--system-configuration)
- [B. CLOUD INFRASTRUCTURE](#section-b-cloud-infrastructure)
- [C. SECURITY & CREDENTIALS](#section-c-security--credentials)
- [D. FRONT-END DEVELOPMENT](#section-d-front-end-development)
- [E. OPS & BUILD SYSTEM](#section-e-ops--build-system)
- [F. OTHERS (Quick Reference)](#section-f-others-quick-reference)

### SKILLS & MCPs
- [Skills](#skills)
- [MCP: cloud-infra](#mcp-cloud-infra)
- [APIs](#apis)

---

# ████████████████████████████████████████████████████████████████████████████
#                                 STACK
# ████████████████████████████████████████████████████████████████████████████

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION A: UNIX (NixOS & System Configuration)
# ══════════════════════════════════════════════════════════════════════════════

> **Full documentation**: See `~/git/unix/README.md`

## A.1 System Overview

| Component | Details |
|-----------|---------|
| **Primary OS** | NixOS 24.11 (Surface Pro 8) |
| **Secondary OS** | Kubuntu (dual-boot, ext4 partition) |
| **Kernel** | linux-surface (mainline 6.15+ with Surface patches) |
| **Desktop** | KDE Plasma 6 (Wayland), GNOME, Openbox available |
| **Shell** | Fish (default), Zsh, Bash available |

## A.2 Key Paths & Build

| Resource | Path |
|----------|------|
| **Unix Repo** | `/home/diego/git/unix` |
| **Surface Host Flake** | `unix/aa_nixos-surface_host/` |
| **Home-Manager Desktop** | `unix/ba_flakes_desktop/` |
| **Home-Manager Termux** | `unix/bb_flakes_termux/` |

```bash
# Rebuild NixOS system
~/git/unix/aa_nixos-surface_host/build.sh    # Cmds: s|switch  b|boot  t|test  c|check  u|update  d|diff  i|install  build {raw|iso|qcow|vm}  burn  (no arg = TUI)

# Rebuild home-manager
~/git/unix/ba_flakes_desktop/build.sh        # Desktop
~/git/unix/bb_flakes_termux/build.sh         # Termux
```

**Host Configs**: `surface-plasma` (all 8 profiles + Plasma 6), `surface-gnome`, `server`, `cli`, `minimal`.

## A.3 Agent-Essential Notes

- **Impermanence**: Root is tmpfs — `/nix` and `/home/*` are persistent btrfs subvolumes
- **LUKS**: Full disk encryption, USB keyfile with password fallback
- **initrd**: Surface keyboard needs `surface_aggregator`, `surface_hid` loaded early
- **No Intel ISH**: Surface Pro 8 uses SAM, not Intel Integrated Sensor Hub
- **Docker/Podman**: Data stored in `/mnt/shared/data/containers/`

## A.4 Terminal Welcome (rendered fish greeting)

```
(fish greeting not available — fish not installed or greeting failed)
```

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION B: CLOUD INFRASTRUCTURE
# ══════════════════════════════════════════════════════════════════════════════

> **Full documentation**: See `~/git/cloud/README.md`

## B.1 Repository & Resources

| Resource | Path | Type |
|----------|------|------|
| **Cloud Repo** | `/home/diego/git/cloud` | Git Repository |
| **Container Configs** | `/home/diego/git/cloud/a_solutions/` | Nix Flakes |
| **Home Manager** | `/home/diego/git/cloud/b_infra/nixhm-sudo-<vm>/` | Per-VM Configs |

## B.2 Virtual Machines

| VM | Alias | IP | WG IP | Description |
|----|-------|-----|-------|-------------|
| oci-E2-f_0 | oci-mail | 130.110.251.193 | 10.0.0.3 | Oracle Free - E2 Micro 0 - Mail Server |
| oci-E2-f_1 | oci-analytics | 129.151.228.66 | 10.0.0.4 | Oracle Free - E2 Micro 1 - Analytics + Workflows |
| oci-A1-f_0 | oci-apps | 82.70.229.129 | 10.0.0.6 | Oracle Free - A1 Flex 0 (4 OCPUs / 24GB / 100GB) — Consolidated |
| gcp-T4-p_0 | gcp-t4 | 34.173.227.250 | 10.0.0.8 | GCloud Paid - N1 Std 4 + T4 GPU (Spot) - Ollama LLM |
| gcp-E2-f_0 | gcp-proxy | 35.226.147.64 | 10.0.0.1 | GCloud Free - E2 Micro 0 - Central Proxy + Control |

## B.3 Networking

Traffic flow: **Cloudflare -> Caddy (gcp-proxy) -> WireGuard -> target VM**. Auth: Authelia 2FA (browser) or Bearer token via introspect-proxy (CLI/API).

SSH aliases: `ssh oci-mail`, `ssh oci-analytics`, `ssh oci-apps`, `ssh gcp-t4`, `ssh gcp-proxy`.

## B.4 Active Services

| Service | Domain | VM | Category |
|---------|--------|-----|----------|
| authelia | auth.diegonmarcos.com | gcp-proxy | sec |
| caddy | proxy.diegonmarcos.com | gcp-proxy | sec |
| hickory-dns | dns.internal | gcp-proxy | cloud |
| dagu | workflows.diegonmarcos.com | oci-analytics | tools |
| dozzle | logs.diegonmarcos.com | oci-analytics | tools |
| c3-infra-api | api.diegonmarcos.com/c3-infra-api | oci-apps | sec |
| c3-infra-mcp | mcp.diegonmarcos.com/c3-infra-mcp | oci-apps | sec |
| c3-services-api | api.diegonmarcos.com/c3-services-api | oci-apps | obs |
| code-server | ide.diegonmarcos.com | oci-apps | app |
| crawlee-cloud | api.diegonmarcos.com | oci-apps | fin |
| dbgate | db.diegonmarcos.com | oci-apps | tools |
| etherpad | pad.diegonmarcos.com | oci-apps | app |
| filebrowser | files.diegonmarcos.com | oci-apps | app |
| fin-api | api.diegonmarcos.com/fin-api | oci-apps | fin |
| gitea | git.diegonmarcos.com | oci-apps | data |
| google-personal-mcp | mcp.diegonmarcos.com | oci-apps | app |
| google-workspace-mcp | mcp.diegonmarcos.com | oci-apps | app |
| grist | sheets.diegonmarcos.com | oci-apps | app |
| hedgedoc | doc.diegonmarcos.com | oci-apps | app |
| openobserve | analytics.diegonmarcos.com/openobserve | oci-apps | tools |
| mail-mcp | mcp.diegonmarcos.com | oci-apps | app |
| matomo | analytics.diegonmarcos.com | oci-apps | tools |
| mattermost-bots | chat.diegonmarcos.com | oci-apps | app |
| ntfy | rss.diegonmarcos.com | oci-apps | tools |
| photoprism | photos.diegonmarcos.com | oci-apps | app |
| radicale | cal.diegonmarcos.com | oci-apps | app |
| umami | analytics.diegonmarcos.com | oci-apps | tools |
| vaultwarden | vault.diegonmarcos.com | oci-apps | mic |
| cypht | webmail.diegonmarcos.com | oci-mail | app |
| maddy | mail.diegonmarcos.com | oci-mail | app |
| mail-puller | mail-puller.diegonmarcos.com | oci-mail | app |
| smtp-proxy | smtp.diegonmarcos.com | oci-mail | app |
| snappymail | webmail.diegonmarcos.com | oci-mail | app |
| stalwart | mail-stalwart.diegonmarcos.com | oci-mail | app |

## B.5 Bearer Token Auth (CLI Access)

```bash
# Get token (interactive, opens browser for 2FA)
python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py

# Use token
TOKEN=$(jq -r .access_token ~/git/vault/A0_keys/providers/authelia/oauth/authelia_tokens.json)
curl -H "Authorization: Bearer $TOKEN" https://<service>.diegonmarcos.com/...
```

> Matomo hybrid toggle, IP change management, security stack details: See `~/git/cloud/README.md`

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION C: SECURITY & CREDENTIALS
# ══════════════════════════════════════════════════════════════════════════════

## C.1 Vault Repository

| Resource | Path |
|----------|------|
| **Vault Repo** | `/home/diego/git/vault` |

**WARNING**: Contains sensitive credentials. NEVER expose or commit to public repos.

## C.2 Vault Structure

```
/home/diego/git/vault/
├── A0_keys/
│   ├── ssh/                  # SSH keys (symlinked to ~/.ssh/)
│   ├── providers/
│   │   ├── authelia/oauth/   # Bearer token + get_token.py
│   │   ├── cloudflare/       # DNS API credentials
│   │   ├── gcloud/           # Google Cloud CLI config
│   │   ├── github/           # GitHub CLI + OAuth tokens
│   │   ├── nocodb/           # NocoDB API tokens
│   │   ├── oci/              # Oracle Cloud CLI config
│   │   ├── system/           # System-level credentials
│   │   └── wireguard/        # VPN keys
│   └── api_tokens.json       # Master credentials file
├── B0_Passwords/             # Service passwords
├── B1_2fa/                   # TOTP seeds + recovery codes
├── B2_Wifi/                  # WiFi connection configs
├── C0_ID/                    # Identity documents
├── C1_Payment/               # Payment card info
├── C2_Notes/                 # Secure notes
└── D0_bitwarden/             # Bitwarden vault export
```

## C.3 Security Stack

| Layer | Components |
|-------|------------|
| **Network Edge** | Cloudflare Proxy, Cloud Firewalls |
| **Traffic** | Caddy Reverse Proxy, Let's Encrypt TLS |
| **Authentication** | Authelia 2FA (TOTP/WebAuthn), OIDC bearer tokens |
| **Token Validation** | introspect-proxy (OIDC introspection sidecar) |
| **Application** | Docker Networks, WireGuard VPN, Container Isolation |
| **Credentials** | Vaultwarden (passwords), Aegis (TOTP) |

## C.4 CLI Authentication

```bash
# GitHub CLI
gh auth status

# Oracle Cloud CLI
oci session authenticate

# Google Cloud CLI
gcloud auth login

# Authelia bearer token (for Caddy-protected services)
python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py
```

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION D: FRONT-END DEVELOPMENT
# ══════════════════════════════════════════════════════════════════════════════

> **Full documentation**: See `~/git/front/README.md` and `~/git/front/1.ops/` for specs

## D.1 Repository & Resources

| Resource | Path |
|----------|------|
| **Front Repo** | `/home/diego/git/front` |
| **Stack Spec** | `/home/diego/git/front/1.ops/00_Stack_Main.md` |
| **Code Practices** | `/home/diego/git/front/1.ops/30_Code_Practise.md` |
| **Master Build** | `/home/diego/git/front/1.ops/build_main.sh` |

## D.2 Build System

```bash
~/git/front/1.ops/build_main.sh           # Interactive TUI (all projects)
~/git/front/1.ops/build_main.sh build     # Build all
~/git/front/<category>/<project>/build.sh build    # Single project
~/git/front/<category>/<project>/build.sh dev      # Dev server
```

## D.3 Code Standards

### TypeScript
- **Strict Mode**: No `any`, handle `null`/`undefined`
- **DOM**: Cast elements explicitly, check null
- **ES Modules**: Use `import`/`export`

### Svelte 5 (Runes Mode) - CRITICAL
```typescript
let { propName }: { propName: Type } = $props();  // Props
let count = $state(0);                             // State
let doubled = $derived(count * 2);                 // Computed
// Events: use standard HTML (onclick, not on:click)
```

### Vue 3 (Composition API)
```typescript
// Always use <script setup lang="ts">
defineProps<{ id: number; name: string }>();
const user = ref<User | null>(null);
```

### SCSS Rules
```scss
@include mq(sm|md|lg|xl)           // Breakpoints
@include flex-center;               // Center anything
@include flex-row(justify, align, gap);
@include grid-auto-fit(min-size, gap);
```

### CRITICAL: NO INLINE CSS
- **NEVER** use `style=""` attributes in HTML
- **ALWAYS** create SCSS classes in appropriate `_*.scss` file
- ALL styling must go through the SCSS build pipeline

### HTML Standards
- **Semantic**: Use `<header>`, `<nav>`, `<main>`, `<section>`, `<article>`, `<footer>`
- **Links vs Buttons**: `<a>` for navigation, `<button>` for actions
- **Accessibility**: All `<img>` have `alt`, inputs have `<label>`

## D.4 Analytics (Matomo)

**Required in every HTML `<head>`:**
```html
<script>
var _mtm = window._mtm = window._mtm || [];
_mtm.push({'mtm.startTime': (new Date().getTime()), 'event': 'mtm.Start'});
(function() {
  var d=document, g=d.createElement('script'), s=d.getElementsByTagName('script')[0];
  g.async=true; g.src='https://analytics.diegonmarcos.com/matomo/js/container_odwLIyPV.js';
  s.parentNode.insertBefore(g,s);
})();
</script>
```

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION E: OPS & BUILD SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

## ⚠️ CRITICAL: NIX WAY — ALWAYS FLAKES IN THE REPO ⚠️

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   NEVER use system-level flakes. Flakes live IN the repository.  ║
║                                                                  ║
║   Every project uses build.sh (engine) + build.json (config)     ║
║   at project root.                                               ║
║                                                                  ║
║   build.sh is the ONLY build interface. ALWAYS use it.           ║
║                                                                  ║
║   NEVER run nix build/switch/etc. directly — use the repo's      ║
║   build.sh.                                                      ║
║                                                                  ║
║   NEVER edit deployed/output files directly (e.g. ~/.claude/,    ║
║   dist/, ~/). ALWAYS find and edit the SOURCE in the git repo    ║
║   flake. This file (CLAUDE.md) is deployed output — its source:  ║
║     ~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/    ║
║     ~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/     ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

### Build Pattern per Repository

| Repo | Pattern | What build.sh does |
|------|---------|-------------------|
| **front/** | `build.sh` + `build.json` per project | Sass/TS/Vite/SvelteKit build, dev server, deploy to GitHub Pages |
| **cloud/** | `build.sh` + `build.json` per service (Nix flake -> Docker Compose) | `build` generates docker-compose.yml, `ship` deploys to VM via SSH |
| **unix/** | `build.sh` per flake (NixOS host, home-manager desktop/termux) | `switch` applies NixOS/home-manager config, `build` builds without applying |

**All three repos follow the same interface**: `build.sh <command>`. NEVER bypass it with raw `npm`, `nix`, `docker-compose`, or other commands.

### GitHub Actions CI/CD (cloud/ repo)

**Cloud repo has GHA workflows** in `.github/workflows/` that auto-deploy on push to `main`:

| Workflow | Trigger (path) | What it does |
|----------|---------------|-------------|
| `ship-gcp-proxy.yml` | `bb-sec_caddy/`, `bb-sec_authelia/`, etc. | Ship services to gcp-proxy |
| `ship-oci-apps.yml` | `bc-obs_c3-infra-mcp-api/`, `bb-sec_rust-api/`, `bc-obs_rig/`, etc. | Ship services to oci-apps (REMOTE_BUILD for Docker) |
| `ship-oci-apps-1.yml` | `aa-sui_*` services | Ship services to oci-apps-1 |
| `ship-oci-mail.yml` | `aa-sui_tools-mailu/`, etc. | Ship services to oci-mail |
| `ship-oci-analytics.yml` | `bc-obs_*` services | Ship services to oci-analytics |
| `ship-home-manager.yml` | `b_infra/**` | Deploy home-manager to all VMs (cascaded by ship-gen-configs) |

All workflows use: `cachix/install-nix-action`, SSH key from secrets, SOPS age key, then `build.sh ship`.
Services with Docker images use `REMOTE_BUILD=true` (builds on target VM, avoids cross-compilation).
All workflows support `workflow_dispatch` for manual triggering with optional service filter.

**IMPORTANT**: Pushing to `main` with changes in `a_solutions/*/src/` triggers auto-deploy. Be aware of this when committing.

### ⚠️ Cloud Service Structure (MANDATORY)

```
⚠️ BEFORE modifying ANY cloud/ service: READ ~/git/cloud/README.md
   THIS IS NOT OPTIONAL — it is the full spec for the cloud build system.
```

Every service in `` MUST follow this exact structure:

```
<category-prefix>_<name>/
├── build.sh        <- Universal engine (DO NOT customize — copy from template)
├── build.json      <- Service config (name, description, deploy target)
└── src/
    ├── flake.nix   <- REQUIRED — Nix flake that builds config files -> dist/
    ├── secrets.yaml <- Optional, sops-encrypted (age key)
    └── ...          <- Service-specific source files
```

**build.json schema** (cloud/ services):
```json
{
  "name": "service-name",
  "description": "What this service does",
  "deploy": {
    "host": "ssh-alias (e.g. gcp-proxy, oci-apps-1) or 'local'",
    "remote_path": "/opt/containers/<service-name>"
  }
}
```

**build.sh pipeline steps** (same for ALL services — NEVER create custom steps):

| Command | What it does |
|---------|-------------|
| `build` | `nix build` in `src/` -> copy result to `dist/` + any extra build steps |
| `secrets` | `sops -d src/secrets.yaml` -> `dist/.secrets` (KEY=VALUE env file) |
| `deploy` | `rsync dist/` -> VM via SSH (or local copy for local services) |
| `compose` | `docker compose up -d` on VM (or equivalent for local services) |
| `all` | `build + secrets` (default) |
| `ship` | `build + secrets + deploy + compose` (FULL PIPELINE — use this to deploy) |
| `clean` | Remove `dist/` and `.result` |

**Template reference**: `bb-sec_authelia/build.sh` — copy this for new services.

**Category prefixes**: `aa-sui_` (app), `ab-mic_` (mic), `ac-fin_` (fin), `ba-clo_` (cloud), `bb-sec_` (sec), `bc-obs_` (tools), `ca-dat_` (data)

## E.1 Working Directory Rule

**ALL Claude Code sessions MUST start from `~/.claude` directory.**
This ensures consistent context loading and access to CLAUDE.md instructions.

## E.1.2 Forbidden Commands (reinforced by hooks)

| NEVER | ALWAYS |
|-------|--------|
| `ssh vm 'echo > .secrets'` | `src/secrets.yaml` + sops + `build.sh ship` |
| `nix-env -i pkg` | Add to flake + rebuild |
| `sed` on VM `/etc/` files | Edit nix source + deploy |
| `docker compose up` on VM | `build.sh compose` |
| `which cmd` | `command -v cmd` |
| Edit `dist/` files | Edit `src/` + `build.sh build` |
| Edit `~/.claude/CLAUDE.md` | Edit source in `~/git/unix/` flakes |
| `cd dir && git mv dir/...` | `git -C /abs/path mv ...` (absolute paths) |
| **`git add -f` / `git add --force`** | **plain `git add` — NEVER bypass gitignore. `-f` force-stages secrets, decrypted keys, sensitive/ — gitignore exists for a reason.** |

Enforced by: `claude-memory.sh` (SessionStart), `declarative-guard.sh` (per-prompt), `pretool-guard.sh` (pre-tool-use warn).
Commit-time defence: `1_workflows/src/hooks/pre-commit` **blocks** any gitignored file from being committed.

## E.2 Dependency Verification (CRITICAL)

**ALWAYS check and install ALL dependencies before declaring a feature complete.**

1. **Research dependencies FIRST** - Check official docs, package info
2. **Check runtime dependencies** - Not just build deps
3. **Test ALL features** - Don't just check "it launches"
4. **Verify helper scripts work** - TEST THEM
5. **Document dependencies** - Add comments explaining WHY

```bash
# Check package dependencies
pacman -Qi <package>        # Arch/NixOS
apt depends <package>       # Debian
rpm -qR <package>           # RPM-based
```

**NEVER remove a feature because dependencies are missing - FIX THE DEPENDENCIES.**

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION F: OTHERS (Quick Reference)
# ══════════════════════════════════════════════════════════════════════════════

## F.1 Primary Paths

| Area | Path |
|------|------|
| Git Root | `/home/diego/git` |
| Front-end | `/home/diego/git/front` |
| Cloud Backend | `/home/diego/git/cloud` |
| Unix/NixOS | `/home/diego/git/unix` |
| Security Vault | `/home/diego/git/vault` |

## F.2 Domains

- **Main**: diegonmarcos.com (Cloudflare DNS)
- **GitHub Pages**: diegonmarcos.github.io

## F.3 Important Notes for Claude

1. **Read specs first**: Before modifying any project, read the relevant spec files
2. **Follow code practices**: TypeScript strict mode, Svelte 5 runes, Vue 3 composition API
3. **Build system**: Use `build.sh` scripts, not manual npm commands
4. **Sensitive data**: vault contains credentials - never expose or commit
5. **Analytics**: All web projects must include Matomo tracking
6. **Ports**: Dev servers have assigned ports (8000-8022) - don't conflict
7. **cloud-data**: Source of truth for cloud infrastructure (auto-injected into this file)

---

# ████████████████████████████████████████████████████████████████████████████
#                           SKILLS & MCPs
# ████████████████████████████████████████████████████████████████████████████

## MCP: code-graph-context (stdio, knowledge graph + infra)

**Source**: `~/git/cloud/a_solutions/bc-obs_code-graph-context-kg-infra-mcp/src/` · **23 tools, 2 resources**

### Section A: Raw JSON Infra Knowledge (17 tools)

#### Specs (9 tools)
| Tool | When to use |
|------|-------------|
| `c3_topology` | Full infrastructure map (VMs, services, networking) |
| `c3_configs` | Generated config (domains, ports, images, routes) |
| `c3_deps` | Cloud service npm dependencies |
| `c3_topology_md` | Human-readable topology |
| `c3_configs_md` | Human-readable configs (Caddy, Authelia, DNS) |
| `c3_deps_front` | Front-end project dependencies |
| `knowledge_service_spec` | Service build.json + flake.nix + topology |
| `knowledge_vm_info` | VM details — IP, WG IP, services, SSH alias |
| `knowledge_services_by_category` | All services grouped by category |

#### Docs (4 tools)
| Tool | When to use |
|------|-------------|
| `c3_docs_overview` | Cloud docs portal overview + index |
| `c3_docs_service` | Service-specific documentation |
| `c3_readme` | Cloud repo README.md |
| `cloud_context` | Dynamic infrastructure summary (compact/full) |

#### Skills (4 tools)
| Tool | When to use |
|------|-------------|
| `skill_cloud_architect` | Infrastructure tasks — deploy, networking, VM lifecycle |
| `skill_frontend_developer` | Front-end project work — build, dev, code standards |
| `skill_debug_ops` | Debug containers, logs, health issues |
| `skill_crawlee_scraping` | Web scraping, data extraction |

### Section B: Octocode — Semantic Code Search (3 tools)
| Tool | When to use |
|------|-------------|
| `octocode_search` | Semantic code search across indexed repositories |
| `octocode_graphrag` | Query code relationship graph — search nodes, get relationships, find paths, overview |
| `octocode_index` | Trigger re-indexing of a repository or directory |

### Section C: CodeGraph-Rust — Graph Analysis (3 stub tools, future)
| Tool | When to use |
|------|-------------|
| `codegraph_trace_call_path` | [Future] Trace full call chains between functions |
| `codegraph_impact_analysis` | [Future] Analyze blast radius of code changes |
| `codegraph_dependencies` | [Future] Query dependency graph for modules/files |

### Resources
| URI | Description |
|-----|-------------|
| `cloud://context/compact` | ~10k token infrastructure summary |
| `cloud://context/full` | ~50k token full infrastructure context |

## MCP: diego-personal-data (stdio, local vault/personal data)

**Source**: `~/git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src/` · **16 tools, READ-ONLY**

| Category | Tools |
|----------|-------|
| Vault | `vault_structure`, `vault_providers`, `vault_ssh_keys`, `vault_passwords_summary`, `vault_2fa_status` |
| Identity | `identity_documents`, `identity_notes`, `identity_read_note` |
| Comms | `comms_email_status`, `comms_whatsapp` (TBD), `comms_notes` (TBD) |
| Media | `media_photos`, `media_git_repos` |
| Finance | `finance_cards`, `finance_wifi` |
| Health | `health_data` (TBD) |

## MCP: cloud-infra

**Repo**: `~/git/cloud/a_solutions/bc-obs_c3-infra-mcp-api/` | **SDK**: `@modelcontextprotocol/sdk ^1.12.0`

### Architecture — Hybrid "Chef + Waiter" Model

| Layer | Tools | What it does |
|-------|-------|-------------|
| **Chef (Native)** | `ssh_exec`, `check_vm`, `docker_ps`, `docker_control`, `docker_logs`, `docker_compose_up` | Direct SSH/Docker — works even if C3 API is down |
| **Chef (Build)** | `build_service`, `build_all`, `build_ship`, `build_docker`, `secrets_status`, `backup_trigger` | Nix build pipeline, deployment, secrets, backups |
| **Chef (Repo)** | `read_file`, `search_repos`, `list_directory`, `reload_config` | Read files across all 5 repos (cloud, unix, vault, front, tools) |
| **Waiter (Read)** | `health_alive`, `health_declared`, `health_deployed`, `health_drift`, `health_status`, `profile_container`, `profile_vm`, `service_list_apis`, `service_get_info`, `service_get_spec`, `service_discover_all` | C3 API — health, profiling, API discovery |
| **Waiter (Write)** | `vm_start`, `vm_stop`, `vm_reset`, `container_start`, `container_stop`, `container_restart`, `service_start`, `service_stop`, `service_api_call` | C3 API — VM/container lifecycle, service API calls |
| **C3 New** | `c3_topology`, `c3_topology_drift`, `c3_topology_security`, `c3_test`, `c3_file`, `c3_report`, `c3_vm_status`, `health_tier1`, `health_tier2`, `health_tier3` | Topology, dynamic tests, file retrieval, tiered health |
| **Front-End** | `front_list_projects`, `front_get_project`, `front_build`, `front_dev_server`, `front_deploy` | 32-project monorepo build, dev servers, CI deploy |
| **Infra** | `list_vms`, `list_services`, `get_service_detail`, `reload_config` | Config introspection from config.json |

**70 Tools** · **9 Resources** (`cloud://config`, `cloud://ssh-config`, `cloud://services-overview`, `cloud://readme`, `cloud://front-projects`, `cloud://c3-api-endpoints`, `cloud://service-apis`, `cloud://services/{name}`, `cloud://vms/{vm_id}`) · **4 Prompts** (`cloud-architect`, `frontend-developer`, `debug-ops`, `crawlee-scraping`)

**Runtime**: `npx tsx` (primary) or Podman/Docker container (fallback)

### Tool Modules

```
src/mcp/tools/
├── infra.ts              # 4 tools — VM/service config introspection
├── repo.ts               # 3 tools — cross-repo file read/search
├── build.ts              # 2 tools — nix build pipeline
├── ssh-tools.ts          # 2 tools — SSH exec, VM health check
├── docker.ts             # 4 tools — container ops via SSH
├── native-ops.ts         # 4 tools — build_ship, docker build, secrets, backup
├── health.ts             # 11 tools — health dashboard, profiling, API discovery
├── control.ts            # 8 tools — VM/container/service lifecycle
├── discovery.ts          # 1 tool  — generic service API proxy
├── cloud.ts              # 7 tools — OCI + GCP cloud operations
├── c3.ts                 # 14 tools — topology, tests, files, tiered health
├── crawlee.ts            # 7 tools — Crawlee Cloud scraping
└── front.ts              # 5 tools — front-end monorepo ops
```

## APIs

| API | URL | Swagger |
|-----|-----|---------|
| **C3 API** (PRIMARY) | `https://api.diegonmarcos.com/c3-api` | `https://api.diegonmarcos.com/c3-api/docs` |
| **Rust API** (LEGACY) | `https://api.diegonmarcos.com/rust-api` | `https://api.diegonmarcos.com/rust-api/docs` |
| **Crawlee API** | `https://api.diegonmarcos.com/crawlee/` | — |

**Cloud CLIs**: `oci`, `gcloud`, `gh`, `terraform` — not covered by MCP.

