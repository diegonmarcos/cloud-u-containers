# Cloud Connect - Design Document

> **Document Type**: Design Decisions & Trade-offs
> **Version**: 2.0
> **Last Updated**: 2026-01-01

---

## 1. Overview

This document explains **why** Cloud Connect is designed the way it is. It covers the key decisions made, alternatives considered, and trade-offs accepted.

---

## 2. Key Design Decisions

### 2.1 Shell Script Entry Point

**Decision**: Use a shell script (`cloud-connect.sh`) as the entry point instead of a compiled binary.

| Option | Pros | Cons |
|--------|------|------|
| **Shell script** | No build step, works everywhere, easy to modify | Slower, limited features |
| Rust binary | Fast, type-safe, powerful CLI | Requires compilation or pre-built binary |
| Python script | Good libraries, readable | Requires Python installed |
| Go binary | Single binary, fast | Requires compilation |

**Chosen**: Shell script

**Rationale**:
- Entry point must work on ANY Linux with Docker
- No assumption about what's installed beyond shell
- User can read/modify the script
- Docker handles the heavy lifting anyway

**Trade-off**: Accept slower startup and simpler logic for maximum portability.

---

### 2.2 Anonymous-First Design

**Decision**: Default to anonymous mode with ProtonVPN. Personal vault is optional.

| Option | Pros | Cons |
|--------|------|------|
| **Anonymous default** | Privacy-first, works without vault | Less convenient for personal use |
| Personal default | Convenient for owner | Requires vault, less flexible |
| Interactive choice | User decides | More complex startup |

**Chosen**: Anonymous default

**Rationale**:
- Primary use case: untrusted computer
- User may not have vault available
- Anonymous browsing is valid complete use case
- Personalization is additive, not required

**Trade-off**: Accept extra steps for personalization to ensure privacy by default.

---

### 2.3 Modular Architecture

**Decision**: Each feature is a separate module that can run independently.

| Option | Pros | Cons |
|--------|------|------|
| **Modular** | Flexible, maintainable, testable | More files, more complexity |
| Monolithic | Simple, single file | Hard to modify, all-or-nothing |
| Plugin system | Very flexible | Over-engineered for this use |

**Chosen**: Modular

**Rationale**:
- User may only need VPN (not tools)
- User may only need tools (not VPN)
- Easier to add/remove features
- Each module can be tested independently

**Trade-off**: Accept more files and structure for flexibility.

---

### 2.4 90% Resource Limits

**Decision**: Container is hard-limited to 90% CPU and 90% RAM.

| Option | Pros | Cons |
|--------|------|------|
| No limits | Maximum performance | Can crash host |
| 50% limits | Very safe | Wastes resources |
| **90% limits** | Near-full performance, safe | Still could slow host |
| Configurable | Flexible | User might misconfigure |

**Chosen**: 90% limits (with override option)

**Rationale**:
- Container should never crash the host system
- 10% reserved keeps host responsive
- OOM killer targets container first
- Can be overridden if user accepts risk

**Trade-off**: Accept 10% performance loss for host stability.

---

### 2.5 Arch Linux Base

**Decision**: Use Arch Linux as the container base image.

| Option | Pros | Cons |
|--------|------|------|
| **Arch Linux** | Rolling release, AUR, latest packages | Larger image, can break |
| Ubuntu | Stable, well-known | Older packages |
| Alpine | Tiny image | Missing packages, musl issues |
| Fedora | Good balance | Less familiar |

**Chosen**: Arch Linux

**Rationale**:
- Latest packages without PPAs
- AUR has everything (Brave, ProtonVPN, etc.)
- pacman is fast
- Target users are developers who know Arch

**Trade-off**: Accept larger image size for package availability.

---

### 2.6 Split Tunnel by Default

**Decision**: When vault is loaded, use split tunnel (cloud via WireGuard, public via ProtonVPN).

| Option | Pros | Cons |
|--------|------|------|
| Full WireGuard | Simple, single VPN | Exposes browsing to personal IP |
| Full ProtonVPN | Anonymous browsing | Cloud access slower |
| **Split tunnel** | Best of both | More complex routing |

**Chosen**: Split tunnel

**Rationale**:
- Cloud infrastructure traffic needs low latency
- Public browsing should stay anonymous
- ISP only sees ProtonVPN connection
- Cloud provider only sees WireGuard connection

**Trade-off**: Accept routing complexity for optimal security/performance.

---

### 2.7 Vault Structure

**Decision**: Vault is a directory with specific structure, not a database or encrypted blob.

| Option | Pros | Cons |
|--------|------|------|
| **Directory structure** | Simple, git-friendly, transparent | No encryption by default |
| SQLite database | Single file, queryable | Opaque, harder to backup |
| Encrypted container | Secure at rest | Need to decrypt entirely |
| Password manager | Existing tools | Different interface |

**Chosen**: Directory structure (optionally encrypted with LUKS or git-crypt)

**Rationale**:
- Easy to understand and modify
- Can be version controlled
- Can be encrypted at directory level
- No special tools needed to read

**Trade-off**: Accept need for external encryption for simplicity.

---

### 2.8 Shell as Default Language

**Decision**: Use shell (bash) for all modules by default. Other languages only when necessary.

| Option | Pros | Cons |
|--------|------|------|
| **Shell default** | Universal, no deps, transparent | Limited features |
| Python default | Powerful, readable | Requires Python |
| Rust default | Fast, safe | Requires compilation |
| Mixed from start | Best tool for job | Inconsistent |

**Chosen**: Shell default, others when needed

**Rationale**:
- Shell is always available
- Most operations are just calling other programs
- Easy to read and modify
- Other languages for complex logic only

**Trade-off**: Accept shell limitations for universality.

---

### 2.9 Openbox vs KDE Plasma

**Decision**: Use Openbox lightweight WM instead of full KDE Plasma desktop.

| Option | Pros | Cons |
|--------|------|------|
| **Openbox** | Lightweight, fast, no systemd deps, works in containers | Minimal features |
| KDE Plasma | Full desktop, familiar | Large, slow, GTK bwrap issues |
| XFCE | Medium weight, familiar | GTK bwrap sandboxing fails in containers |
| No desktop | Smallest, fastest | CLI only, no GUI apps |

**Chosen**: Openbox + Qt apps (Dolphin, Konsole)

**Rationale**:
- KDE Plasma and XFCE crash in Docker due to GTK4's bwrap sandboxing
- Qt apps (Dolphin, Konsole) work fine without sandboxing issues
- Openbox is lightweight and has no systemd dependencies
- VNC provides remote access without X11 forwarding complexity

**Trade-off**: Accept minimal desktop for container compatibility.

---

### 2.10 VNC vs X11 Forwarding

**Decision**: Use VNC for remote desktop access, X11 for local.

| Option | Pros | Cons |
|--------|------|------|
| **VNC** | Works anywhere, persistent session | Extra network hop |
| X11 only | Direct, fast | Requires host display, no remote |
| Both | Flexibility | More complexity |

**Chosen**: VNC (disabled by default) + X11 socket sharing

**Rationale**:
- VNC allows remote access from any VNC client
- X11 socket sharing works for local host access
- Disabled by default to save resources
- Enable with `CLOUD_START_VNC=1`

**Trade-off**: Accept optional VNC for maximum flexibility.

---

### 2.11 AI CLI Tools in Base Image

**Decision**: Include Claude CLI and Gemini CLI in the base image.

| Option | Pros | Cons |
|--------|------|------|
| **Include in base** | Ready to use, no setup | Larger image |
| Optional module | Smaller base | Extra step to install |
| Not included | Smallest base | User must install manually |

**Chosen**: Include Claude CLI and Gemini CLI in base

**Rationale**:
- AI tools are primary use case for many users
- Installation during build caches properly
- No API keys in image (configured at runtime)
- Global symlinks for easy access

**Trade-off**: Accept larger image for immediate AI capabilities.

---

## 3. Alternatives Rejected

### 3.1 Nix/NixOS

**Considered**: Use Nix for reproducible environment.

**Rejected because**:
- Steep learning curve
- Large download size
- Not common on host systems
- Docker already provides isolation

### 3.2 Podman Instead of Docker

**Considered**: Use Podman for rootless containers.

**Rejected because**:
- Docker is more common
- Podman has some compatibility issues
- Can be added as alternative later

### 3.3 Flatpak/Snap for Apps

**Considered**: Install apps via Flatpak/Snap in container.

**Rejected because**:
- Adds another layer of isolation (container in container)
- Larger disk usage
- Slower startup
- Native packages work fine

### 3.4 GUI Configuration Tool

**Considered**: Build a GUI for configuration.

**Rejected because**:
- CLI is sufficient
- GUI adds complexity
- TUI can be added later if needed
- Target users prefer CLI

### 3.5 Cloud-Based Vault Sync

**Considered**: Automatically sync vault from cloud.

**Rejected because**:
- Adds network dependency
- Security concerns
- User should explicitly load vault
- Can be added as optional module

---

## 4. Trade-off Summary

| Decision | Gained | Lost |
|----------|--------|------|
| Shell entry point | Portability | Performance, features |
| Anonymous default | Privacy | Convenience |
| Modular design | Flexibility | Simplicity |
| 90% resource limits | Host stability | 10% performance |
| Arch Linux base | Package availability | Image size |
| Split tunnel | Security + performance | Complexity |
| Directory vault | Transparency | Built-in encryption |
| Shell as default | Universality | Advanced features |
| Openbox over KDE | Container compatibility | Desktop features |
| VNC access | Remote flexibility | Extra network hop |
| AI CLIs in base | Ready to use | Larger image |

---

## 5. Future Considerations

### 5.1 May Add Later

| Feature | Reason to Add | Barrier |
|---------|---------------|---------|
| TUI interface | Better UX | Requires Rust/Go |
| Podman support | Rootless option | Testing needed |
| macOS support | Broader audience | Docker differences |
| Cloud vault sync | Convenience | Security concerns |
| Automatic updates | Fresh packages | Bandwidth, stability |

### 5.2 Will Not Add

| Feature | Reason |
|---------|--------|
| Windows support | Fundamentally different, out of scope |
| Non-Docker runtime | Docker is the standard |
| Web-based UI | Over-engineering |
| Multi-user support | Single-user tool |

---

## 6. Design Principles

### 6.1 Guiding Principles

1. **Portability over Performance**
   - Works everywhere is better than works fast somewhere

2. **Privacy by Default**
   - Anonymous is the starting state
   - Personal data is opt-in

3. **Explicit over Implicit**
   - User loads vault explicitly
   - User installs tools explicitly
   - No hidden network calls

4. **Simplicity over Features**
   - Shell script over compiled binary
   - Directory vault over encrypted database
   - Fewer options, sensible defaults

5. **Safety over Power**
   - Resource limits enforced
   - Read-only vault mount
   - No host root access

### 6.2 When to Deviate

Deviate from these principles when:
- Security would be compromised
- Core functionality would break
- User explicitly requests (and accepts risk)

---

## 7. Security Design Decisions

### 7.1 Container Privileges

**Decision**: Container runs with limited capabilities, not `--privileged`.

**Exceptions**:
- `CAP_NET_ADMIN` for VPN
- `CAP_SYS_ADMIN` for FUSE (if needed)

**Rationale**: Minimum necessary privileges.

### 7.2 Volume Mounts

**Decision**: Only mount what's needed.

| Mount | Mode | Purpose |
|-------|------|---------|
| X11 socket | Read-only | Display |
| Vault | Read-only | Credentials |
| Home | Read-write | User data |

**Rationale**: Limit container's access to host filesystem.

### 7.3 Network Isolation

**Decision**: All traffic goes through VPN by default.

**Exceptions**:
- Local LAN traffic (192.168.x.x)
- Localhost (127.0.0.1)

**Rationale**: No unencrypted internet traffic.

---

## 8. Performance Design Decisions

### 8.1 Image Layers

**Decision**: Use multi-stage build with cached layers.

```dockerfile
# Layer 1: Base system (rarely changes)
FROM archlinux:latest
RUN pacman -Syu

# Layer 2: Core tools (occasionally changes)
RUN pacman -S base-devel git

# Layer 3: VPN/DNS (rarely changes)
RUN pacman -S wireguard-tools protonvpn-cli

# Layer 4: User configs (frequently changes)
COPY configs/ /etc/cloud-connect/
```

**Rationale**: Rebuild only what changed.

### 8.2 Lazy Loading

**Decision**: Only install tools when requested.

- Base image: ~1GB (VPN, DNS, browser)
- With tools: ~4GB (adds dev stack)
- With desktop: ~8GB (adds KDE)

**Rationale**: Fast initial start, pay for features when needed.

---

## 9. Usability Design Decisions

### 9.1 Command Naming

**Decision**: Use short, memorable commands.

| Command | Meaning |
|---------|---------|
| `cloud tools install` | Install development tools |
| `cloud vpn up` | Connect VPN |
| `cloud mount up` | Mount filesystems |

**Rationale**: Consistent verb patterns, easy to remember.

### 9.2 Error Messages

**Decision**: Clear, actionable error messages.

```
BAD:  Error: exit code 1
GOOD: Error: ProtonVPN not connected. Run 'cloud vpn up' first.
```

**Rationale**: User should know what to do next.

### 9.3 Progress Feedback

**Decision**: Show progress for long operations.

```
[1/4] Installing Python...
[2/4] Installing Node.js...
[3/4] Installing Rust...
[4/4] Installing Go...
Done! All tools installed.
```

**Rationale**: User knows something is happening.

---

## 10. References

- [SPEC.md](SPEC.md) - Requirements and features
- [ARCHITECTURE.md](ARCHITECTURE.md) - System structure
- [IMPLEMENTATION.md](IMPLEMENTATION.md) - Build phases and tasks

---

*End of Design Document*
