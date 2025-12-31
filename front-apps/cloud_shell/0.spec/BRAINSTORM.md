# Cloud Shell - Brainstorm

> **Status:** Brainstorm / Concept
> **Date:** 2025-12-30
> **Type:** Tauri Desktop App

---

## 1. Core Insight: Renderers

Everything visual is a renderer for some format:

```
RENDERER              INPUT FORMAT              OUTPUT
────────              ────────────              ──────

Browser               HTML/CSS/JS               Web pages
Terminal              ANSI + Text               CLI interface
PDF Viewer            PDF                       Documents
Video Player          MP4/MKV                   Video frames
GPU                   Shaders                   Pixels
```

**Key Realization:**
- Terminal = "Browser" for CLI apps
- Shell = "Web app" that runs in the terminal
- ANSI codes = "HTML/CSS" of terminals

---

## 2. Why Tauri Instead of Terminal?

### Same Concept, Better Renderer

```
TRADITIONAL                          TAURI SHELL
───────────                          ───────────

Shell → ANSI → Terminal              Shell (Rust) → JSON → WebView
             ↓                                            ↓
        Text grid                              Full HTML/CSS/JS UI
```

### What Each Layer Does

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   BACKEND (Rust)              FRONTEND (WebView)                │
│   Does EVERYTHING             Dumb renderer                     │
│   ──────────────────          ─────────────────                 │
│                                                                  │
│   • SSH ✓                     • Receives JSON                   │
│   • Pipes ✓                   • Renders HTML                    │
│   • Fork/exec ✓               • Shows pretty UI                 │
│   • File I/O ✓                • Sends user input back           │
│   • Network ✓                                                   │
│   • ALL system calls ✓        That's it.                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### NO Limitations

The renderer does NOT limit the backend:

| Feature | Terminal | Tauri | Notes |
|---------|----------|-------|-------|
| SSH to servers | ✓ | ✓ | Backend handles it |
| Pipes | ✓ | ✓ | Backend handles it |
| Run commands | ✓ | ✓ | Backend handles it |
| Interactive apps (vim, htop) | ✓ | ✓ | xterm.js renders ANSI |
| Rich UI | ✗ | ✓ | HTML/CSS advantage |
| Charts/graphs | ASCII only | ✓ | SVG, Canvas, D3.js |
| Click interactions | ✗ | ✓ | Full mouse support |

---

## 3. ANSI → HTML Conversion

Terminal apps output ANSI codes. Tauri can render them:

```
ANSI                              HTML/CSS
────                              ────────

\x1b[31mRed\x1b[0m        →       <span style="color:red">Red</span>
\x1b[1;32mBold Green   →       <span class="bold green">
\x1b[44mBlue BG      →       <span style="background:blue">
```

**Or use xterm.js** - full terminal emulator in JavaScript:
- Handles ALL ANSI codes
- Cursor movement
- Colors (256 + true color)
- Interactive apps (vim, htop work perfectly)
- Mouse support

---

## 4. AI-Native Shell Design

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│   USER TYPES: "check if my servers are ok"                      │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                      INTENT RESOLVER                             │
│                                                                  │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐        │
│   │ Traditional │    │   LLM       │    │  Context    │        │
│   │   Parser    │    │  Resolver   │    │  Engine     │        │
│   └─────────────┘    └─────────────┘    └─────────────┘        │
│                                                                  │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                      ACTION PLANNER                              │
│                                                                  │
│   ╭─ Plan ────────────────────────────────────────────────────╮ │
│   │ 1. ssh gcp "docker ps" → check containers                 │ │
│   │ 2. ping 34.55.55.234 → check connectivity                 │ │
│   │ 3. curl https://proxy.diegonmarcos.com → check http       │ │
│   ╰───────────────────────────────────────────────────────────╯ │
│   [Run] [Edit] [Explain] [Cancel]                               │
│                                                                  │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                       EXECUTOR                                   │
│                                                                  │
│   Process (fork/exec) │ API (http) │ Agent (multi-step)        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Key Differences from Traditional Shells

| Aspect | Traditional | AI-Native |
|--------|-------------|-----------|
| Input | Exact syntax required | Intent-based + exact both work |
| Errors | "command not found" | "Did you mean...? Here's how..." |
| Discovery | `man`, `--help` | "how do I...?" |
| Complex tasks | Write script | Describe goal, AI plans steps |
| Output | Text stream | Structured + summarized |
| Safety | Run anything | Preview dangerous commands |
| Context | Stateless | Knows your project, history, infra |

---

## 5. Fish-Style Autocomplete (Enhanced)

### Terminal vs Tauri Autocomplete

```
FISH (Terminal)                    TAURI SHELL (HTML/CSS)

$ docker co│ntainer ls             $ docker co│
           └─gray ghost text                  │
                                              ▼
                                   ┌─────────────────────────┐
                                   │ 🐳 container   subcommand│
                                   │ 📋 compose     subcommand│
                                   │ 📄 config      show config│
                                   ├─────────────────────────┤
                                   │ History:                 │
                                   │ ↺ docker compose up -d  │
                                   └─────────────────────────┘
```

### Autocomplete Sources

```
1. HISTORY                 Most recent matching commands
2. COMMANDS                Executables in $PATH
3. PATHS                   Files and directories
4. FLAGS                   --help, -v, etc (from man pages)
5. ARGUMENTS               Context-aware (git branches, docker containers)
6. CUSTOM                  Your cloud commands (VMs, services)
7. AI                      Natural language → command
```

### Rich Context-Aware Suggestions

```
$ cloud health --│
                 │
┌────────────────▼─────────────────────────────────────────────────┐
│  FLAGS                                                            │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │  --json         Output as JSON                               ││
│  │  --verbose      Show detailed output                         ││
│  │  --watch        Continuous monitoring                        ││
│  └──────────────────────────────────────────────────────────────┘│
│                                                                   │
│  VMS (live status from your infrastructure)                      │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │  gcp           GCP Hub (34.55.55.234) ● online               ││
│  │  oci-flex      OCI Flex (84.235.234.87) ○ sleeping           ││
│  │  oci-mail      OCI Mail (130.110.251.193) ● online           ││
│  └──────────────────────────────────────────────────────────────┘│
│                                                                   │
│  HISTORY                                                         │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │  ↺ cloud health --json > report.json          (2 hours ago)  ││
│  │  ↺ cloud health gcp --verbose                 (yesterday)    ││
│  └──────────────────────────────────────────────────────────────┘│
└───────────────────────────────────────────────────────────────────┘
```

### Feature Set

```
✓ Ghost text (Fish-style inline)
✓ Dropdown with rich UI
✓ Icons per suggestion type
✓ Live status indicators (VM online/offline)
✓ Grouped suggestions (commands, flags, history)
✓ Fuzzy matching with highlights
✓ Keyboard navigation (↑↓ Tab Enter Esc)
✓ Click to select
✓ History with timestamps
✓ AI natural language → command
✓ Context-aware (git branches, docker containers, your VMs)
✓ Preview pane (show what command will do)
✓ Descriptions from man pages
```

---

## 6. RAM Usage Analysis

### Comparison

```
COMPONENT                          TYPICAL RAM
─────────                          ───────────

Bash shell                         ~5 MB
Fish shell                         ~8 MB
Konsole (terminal emulator)        ~40 MB
Alacritty (GPU terminal)           ~30 MB

Electron app (bundles Chromium)    ~150-300 MB      ← heavy
Tauri app (system WebView)         ~50-80 MB        ← much lighter

VS Code                            ~300-800 MB
Chrome (1 tab)                     ~100-200 MB
```

### Tauri Shell Breakdown

```
Rust backend process            ~5-10 MB
System WebView (WebKitGTK)      ~30-50 MB
xterm.js + terminal buffer      ~5-15 MB
Frontend (Svelte/Vue)           ~5-10 MB
Autocomplete index              ~2-5 MB
───────────────────────────────────────────
TOTAL                           ~50-90 MB
```

### Conclusion

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   TAURI SHELL ≈ TERMINAL + SHELL                                │
│                                                                  │
│   ~50-80 MB RAM                                                 │
│   Same as running Konsole + Fish                                │
│   But with full HTML/CSS/JS UI                                  │
│                                                                  │
│   3-4x LIGHTER than Electron                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. Architecture Overview

### Project Structure

```
cloud_shell/
├── src-tauri/              # Rust backend
│   ├── src/
│   │   ├── main.rs
│   │   ├── commands/       # Tauri commands
│   │   │   ├── shell.rs    # execute_command()
│   │   │   ├── ssh.rs      # ssh_exec(), ssh_interactive()
│   │   │   ├── autocomplete.rs
│   │   │   └── health.rs
│   │   └── lib.rs
│   ├── Cargo.toml
│   └── tauri.conf.json
│
├── src/                    # Frontend (Svelte)
│   ├── App.svelte
│   ├── components/
│   │   ├── Terminal.svelte     # xterm.js wrapper
│   │   ├── Autocomplete.svelte # Rich suggestions
│   │   ├── HealthTable.svelte  # Rich output
│   │   ├── VmCard.svelte
│   │   └── Chart.svelte
│   └── lib/
│       └── commands.ts
│
├── package.json
└── vite.config.js
```

### How It Connects to Other Projects

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│                    cloud_control_lib                            │
│                    (Rust core library)                          │
│                           │                                      │
│          ┌────────────────┼────────────────┐                    │
│          │                │                │                    │
│          ▼                ▼                ▼                    │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐            │
│   │ control_cli │  │ control_api │  │ cloud_shell │            │
│   │  (terminal) │  │   (REST)    │  │  (Tauri)    │            │
│   └─────────────┘  └─────────────┘  └─────────────┘            │
│         │                │                │                     │
│         ▼                ▼                ▼                     │
│   SSH sessions      Web dashboard     Desktop app              │
│   Scripts           Mobile app        Rich UI                  │
│   Automation        Integrations      Notifications            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. Example UI Mockups

### Health Dashboard with Charts

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  $ health                                                                    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │         CPU Usage Over Time              [Export] [Refresh]             ││
│  │   100%│                                                                 ││
│  │    80%│      ╭──╮                                                       ││
│  │    60%│  ╭───╯  ╰───╮        ╭──╮                                       ││
│  │    40%│──╯          ╰────────╯  ╰──────                                 ││
│  │    20%│                                                                 ││
│  │     0%└─────────────────────────────────────────────────                ││
│  │        10:00    11:00    12:00    13:00    14:00                        ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                       │
│  │ GCP Hub  │ │ OCI Flex │ │ OCI Mail │ │ OCI Ana  │  ← Click to expand   │
│  │ ● Online │ │ ◐ Warn   │ │ ● Online │ │ ● Online │                       │
│  │ 4 cont.  │ │ 3 cont.  │ │ 5 cont.  │ │ 2 cont.  │                       │
│  │ [SSH]    │ │ [Wake]   │ │ [SSH]    │ │ [SSH]    │                       │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘                       │
│                                                                              │
│  $ _                                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Interactive SSH Session with htop

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Tab: GCP SSH │ Tab: OCI SSH │ Tab: Local │ Tab: Dashboard                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  diego@gcp:~$ htop                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │ CPU[||||||||||||        32%]   Tasks: 42, 1 running              │       │
│  │ Mem[|||||||             1.2G/4G]                                 │       │
│  │                                                                   │       │
│  │  PID  USER   CPU%  MEM%  COMMAND                                 │       │
│  │  1234 root   12.0  4.2   docker                                  │       │
│  │  5678 diego   8.0  2.1   npm                                     │       │
│  └──────────────────────────────────────────────────────────────────┘       │
│                                                                              │
│  ← xterm.js renders htop perfectly, interactive, colors, everything        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Natural Language with AI

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  $ restart the photoprism container on the flex vm                          │
│                                                                              │
│  ╭─ Plan ────────────────────────────────────────────────────────────────╮  │
│  │ ssh oci-flex "docker restart photoprism"                              │  │
│  ╰───────────────────────────────────────────────────────────────────────╯  │
│  [Run] [Edit] [Explain]                                                     │
│                                                                              │
│  > run                                                                      │
│                                                                              │
│  ✓ photoprism restarted (was up 3d, now 2s)                                │
│                                                                              │
│  $ _                                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. The Three Projects

### Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CLOUD ECOSYSTEM                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                      cloud_control_lib                               │   │
│   │                      (Rust Core Library)                             │   │
│   │                                                                      │   │
│   │   health:: │ vms:: │ services:: │ containers:: │ ssh:: │ wake::    │   │
│   │                                                                      │   │
│   │   THE "BRAIN" - All business logic lives here                       │   │
│   └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                           │
│            ┌─────────────────────┼─────────────────────┐                    │
│            │                     │                     │                    │
│            ▼                     ▼                     ▼                    │
│   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐          │
│   │  CLOUD CONNECT  │   │  CLOUD CONTROL  │   │   CLOUD SHELL   │          │
│   │                 │   │                 │   │                 │          │
│   │  Portable       │   │  API Server +   │   │  Tauri Desktop  │          │
│   │  Workstation    │   │  CLI Tool       │   │  App            │          │
│   │  Setup          │   │                 │   │                 │          │
│   └────────┬────────┘   └────────┬────────┘   └────────┬────────┘          │
│            │                     │                     │                    │
│            ▼                     ▼                     ▼                    │
│   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐          │
│   │ User on unsafe  │   │ Web dashboards  │   │ Rich desktop    │          │
│   │ computer        │   │ Automation      │   │ experience      │          │
│   │ Docker sandbox  │   │ Scripts         │   │ AI-powered      │          │
│   │ VPN + sync      │   │ Mobile apps     │   │ Visual UI       │          │
│   └─────────────────┘   └─────────────────┘   └─────────────────┘          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Project 1: Cloud Connect

**Purpose:** Portable secure workstation for untrusted computers

**Use Case:** You're at a friend's house, library, or borrowed laptop. Run one command, get your full secure environment.

**Features:**
- Docker sandbox isolation (don't touch host system)
- VPN split tunnel (WireGuard for cloud, Proton for public internet)
- Encrypted DNS (DoH/DoT)
- FUSE mounts + rclone bisync (access cloud files)
- Tool installation with configs (Brave, Obsidian, Konsole, Kate, Dolphin)
- Bootstrap orchestration (one command sets up everything)

**CLI:**
```
cloud-connect bootstrap          # Full setup
cloud-connect sandbox create     # Docker environment
cloud-connect network wg up      # VPN to cloud
cloud-connect sync mount         # Mount cloud files
cloud-connect tools install      # Install apps with configs
```

**Location:** `cloud_connect/0.spec/CLOUD_CONNECT.md`

---

### Project 2: Cloud Control

**Purpose:** The "brain" - API server + CLI for infrastructure management

**Use Case:** Powers web dashboards, automation scripts, and direct CLI usage.

**Features:**
- Health monitoring (external ping/HTTP/SSL + internal SSH checks)
- VM management (list, status, start, stop, reset)
- Container control (start, stop, restart, logs)
- Service status
- Domain and SSL checks
- Wake-on-demand
- JSON/Markdown export
- REST API for dashboards

**CLI:**
```
cloud-control health             # Quick health status
cloud-control health --json      # JSON output
cloud-control vms                # List VMs
cloud-control vms gcp start      # Start a VM
cloud-control containers gcp     # List containers
cloud-control export health      # Export health report
```

**API:**
```
GET  /health
GET  /vms
GET  /vms/{id}/status
POST /vms/{id}/start
GET  /services
GET  /domains/{domain}/ssl
POST /wake/trigger
GET  /dashboard/summary
```

**Location:** `cloud_control/0.spec/CLOUD_CONTROL.md`

---

### Project 3: Cloud Shell (This Document)

**Purpose:** Rich desktop experience with AI-powered shell

**Use Case:** Daily driver for cloud management with beautiful UI, not just text.

**Features:**
- Tauri app (Rust backend + HTML/CSS/JS frontend)
- Full terminal emulation (xterm.js)
- Rich output rendering (tables, charts, cards)
- Fish-style autocomplete with enhancements
- AI intent resolution (natural language → commands)
- Context-aware suggestions (your VMs, services, history)
- System tray + notifications
- Multiple SSH sessions in tabs

**Location:** This file (`cloud_shell/0.spec/BRAINSTORM.md`)

---

### How They Share Code

```rust
// cloud_control_lib - shared by all three projects

// Cloud Connect uses:
use cloud_control_lib::ssh;        // SSH connections
use cloud_control_lib::health;     // Verify cloud is reachable

// Cloud Control CLI uses:
use cloud_control_lib::health;     // Health checks
use cloud_control_lib::vms;        // VM management
use cloud_control_lib::containers; // Container ops
use cloud_control_lib::services;   // Service status

// Cloud Control API uses:
use cloud_control_lib::*;          // Everything

// Cloud Shell uses:
use cloud_control_lib::*;          // Everything
// + xterm.js for terminal
// + AI layer for intent resolution
```

---

### When to Use Which

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   CLOUD CONNECT - Use when:                                     │
│   ─────────────────────────                                     │
│   • On untrusted/borrowed computer                              │
│   • Need isolated environment                                   │
│   • Setting up fresh machine                                    │
│   • Want full workstation with your configs                     │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   CLOUD CONTROL CLI - Use when:                                 │
│   ─────────────────────────────                                 │
│   • SSH'd into a server                                         │
│   • Writing automation scripts                                  │
│   • Quick one-off commands                                      │
│   • Piping output to other tools                                │
│   • Headless/minimal environment                                │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   CLOUD CONTROL API - Use when:                                 │
│   ────────────────────────────                                  │
│   • Powering web dashboards                                     │
│   • Mobile app backend                                          │
│   • Integration with other services                             │
│   • Webhooks and automation                                     │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   CLOUD SHELL - Use when:                                       │
│   ─────────────────────                                         │
│   • Daily desktop use                                           │
│   • Want rich visual interface                                  │
│   • Multiple SSH sessions                                       │
│   • Prefer GUI over pure terminal                               │
│   • Want AI assistance                                          │
│   • Monitoring dashboards                                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### File Locations

```
back-System/cloud/a_solutions/front-apps/
├── cloud_connect/
│   └── 0.spec/
│       └── CLOUD_CONNECT.md       # Portable workstation spec
│
├── cloud_control/
│   └── 0.spec/
│       └── CLOUD_CONTROL.md       # API + CLI engine spec
│
└── cloud_shell/
    └── 0.spec/
        └── BRAINSTORM.md          # This file - Tauri shell ideas
```

---

## 10. Rendering Technology Deep Dive

> Understanding the full stack from code to pixels

### The Rendering Landscape

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RENDERING APPROACHES                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   WEB-BASED (Browser)              NATIVE (No Browser)                      │
│   ─────────────────────            ────────────────────                     │
│                                                                              │
│   HTML/CSS/JS                      Rust + Shaders (WGSL/GLSL)               │
│        │                                  │                                  │
│        ▼                                  ▼                                  │
│   Browser Engine                   Graphics API                             │
│   (Chromium/WebKit)                (wgpu/Vulkan/Metal)                      │
│        │                                  │                                  │
│        ▼                                  ▼                                  │
│   WebGL/WebGPU                     GPU Driver                               │
│        │                                  │                                  │
│        └──────────────┬───────────────────┘                                 │
│                       ▼                                                      │
│                      GPU                                                     │
│                       │                                                      │
│                       ▼                                                      │
│                    Pixels                                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### CPU Graphics vs GPU Graphics

| Aspect | CPU Rendering | GPU Rendering |
|--------|---------------|---------------|
| Language | Rust, C, any | Shaders (WGSL, GLSL, HLSL) |
| Parallelism | Limited (threads) | Massive (thousands of cores) |
| Use case | Logic, layout, simple 2D | 3D, effects, complex 2D |
| Example | Software rasterizer | Games, video, modern UIs |

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     CPU vs GPU CODE SPLIT                                    │
├─────────────────────────────────┬───────────────────────────────────────────┤
│        CPU CODE                 │          GPU CODE                          │
│        (Rust)                   │          (Shaders)                         │
│                                 │                                            │
│  • Game logic                   │  • Pixel coloring                          │
│  • Physics calculations         │  • 3D transformations                      │
│  • UI state management          │  • Lighting calculations                   │
│  • Network requests             │  • Post-processing effects                 │
│  • File I/O                     │  • Texture sampling                        │
│                                 │                                            │
│         ↓                       │            ↓                               │
│       WASM                      │     GLSL/WGSL/SPIR-V                       │
│   (runs on CPU)                 │     (runs on GPU)                          │
└─────────────────────────────────┴───────────────────────────────────────────┘
```

### GPU Language Families

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    GPU LANGUAGE ECOSYSTEM                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   GRAPHICS (Shaders)                COMPUTE (ML/Science)                    │
│   ──────────────────                ────────────────────                    │
│                                                                              │
│   GLSL (OpenGL)                     CUDA (NVIDIA only)                      │
│   HLSL (DirectX)                    OpenCL (cross-platform)                 │
│   MSL (Metal)                       ROCm/HIP (AMD)                          │
│   WGSL (WebGPU)                     SYCL (Intel oneAPI)                     │
│   SPIR-V (intermediate)             XLA/JAX (Google TPU/GPU)                │
│                                                                              │
│   Purpose: Render pixels            Purpose: Parallel computation           │
│   Output: Images, 3D scenes         Output: Matrices, tensors               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### WASM + Shaders: The Full Stack

**Key Insight:** WASM and Shaders are NOT alternatives - they work together.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     RUST → BROWSER WITH GPU                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │                        YOUR CODE                                    │    │
│   │                                                                     │    │
│   │   Rust + wgpu ──────► WASM + auto-generated JS bindings            │    │
│   │                              ↓                                      │    │
│   │                       tiny JS glue                                  │    │
│   │                              ↓                                      │    │
│   │                       WebGPU API                                    │    │
│   │                              ↓                                      │    │
│   │                       Your WGSL shaders → GPU                       │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│   BUILD COMMANDS:                                                           │
│   ───────────────                                                           │
│   cargo build --release        # Native (Vulkan/Metal/DX12)                │
│   wasm-pack build --target web # Browser (WebGPU)                          │
│                                                                              │
│   SAME Rust code, SAME WGSL shaders → TWO platforms                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Native Rendering Stack (No Browser)

When rendering natively without a browser, you need:

| Component | Browser Provides | Native Equivalent |
|-----------|------------------|-------------------|
| Window creation | Browser window | **winit**, GLFW, SDL2 |
| Render context | `<canvas>` + WebGL | **wgpu surface** |
| Shader execution | WebGL/WebGPU impl | **wgpu** → Vulkan/Metal/DX12 |
| Display compositor | Browser + OS | **OS Display Server** |
| WASM runtime | V8/SpiderMonkey | **Wasmtime, Wasmer** |

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    NATIVE RENDERING STACK                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                      YOUR APPLICATION                                │   │
│   │                     (Rust code + shaders)                            │   │
│   └─────────────────────────────┬───────────────────────────────────────┘   │
│                                 │                                            │
│               ┌─────────────────┴─────────────────┐                         │
│               ▼                                   ▼                         │
│   ┌─────────────────────┐             ┌─────────────────────┐              │
│   │  WINDOWING LIBRARY  │             │    GRAPHICS API     │              │
│   │      (winit)        │◄───────────►│      (wgpu)         │              │
│   │                     │   surface   │                     │              │
│   │ • Creates window    │   handle    │ • Renders shaders   │              │
│   │ • Handles input     │             │ • GPU communication │              │
│   │ • Event loop        │             │ • Buffer management │              │
│   └─────────────────────┘             └─────────────────────┘              │
│               │                                   │                         │
│               ▼                                   ▼                         │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                      DISPLAY SERVER (OS)                             │   │
│   │    Linux: X11 / Wayland    Windows: Win32    macOS: Cocoa           │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### "Browser for Shaders" - Standalone Tools

Tools that render shaders without a browser:

| Tool | Purpose | Install |
|------|---------|---------|
| **glslViewer** | CLI shader renderer | `sudo pacman -S glslviewer` |
| **SHADERed** | Full shader IDE | `yay -S shadered` |
| **Bonzomatic** | Live shader coding | github.com/Gargaj/Bonzomatic |
| **Wasmtime** | Run .wasm natively | `sudo pacman -S wasmtime` |
| **Wasmer** | WASM runtime + WASI | `curl https://get.wasmer.io -sSfL \| sh` |

### Rust UI Frameworks (Alternative to HTML/CSS/JS)

If we want to skip web technologies entirely:

| Framework | Architecture | Separation Style |
|-----------|--------------|------------------|
| **Slint** | Separate .slint files | Most like HTML/CSS/JS |
| **Dioxus** | JSX-like in Rust | React-like components |
| **Iced** | Model-View-Update | Elm architecture |
| **egui** | Immediate mode | Less separation |
| **Leptos** | Signals + RSX | SolidJS-like |

**Slint Example (closest to web mental model):**

```
project/
├── src/
│   └── main.rs          # Logic only (like JS)
├── ui/
│   ├── main.slint       # Structure (like HTML)
│   ├── widgets.slint    # Components
│   └── theme.slint      # Styles (like CSS)
└── Cargo.toml
```

```slint
// ui/main.slint (structure + style - like HTML+CSS)
export component MainWindow inherits Window {
    background: #1a1a2e;

    VerticalLayout {
        padding: 20px;

        Text { text: "Hello"; color: white; }
        Button { text: "Click"; clicked => { root.handle_click() } }
    }
}
```

```rust
// main.rs (logic only - like JS)
fn main() {
    let ui = MainWindow::new();
    ui.on_handle_click(|| println!("Clicked!"));
    ui.run();
}
```

### Could We Skip HTML/CSS/JS for Cloud Shell?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    ALTERNATIVE STACKS FOR CLOUD SHELL                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   OPTION A: Current (Tauri + xterm.js)                                      │
│   ─────────────────────────────────────                                     │
│   Rust backend + HTML/CSS/JS frontend + xterm.js                            │
│   ✓ Fast to build, xterm.js works                                          │
│   ✗ Still uses web tech                                                     │
│                                                                              │
│   OPTION B: Pure Rust (Iced/Slint + custom terminal)                        │
│   ─────────────────────────────────────                                     │
│   Rust + Slint UI + custom terminal widget                                  │
│   ✓ No web tech at all                                                      │
│   ✗ Must build terminal emulator from scratch                               │
│   ✗ No xterm.js equivalent in Rust ecosystem                               │
│                                                                              │
│   OPTION C: GPUI (Zed's approach)                                           │
│   ─────────────────────────────────────                                     │
│   100% Rust + GPU shaders                                                   │
│   ✓ Maximum performance                                                     │
│   ✗ Must build everything from scratch                                      │
│   ✗ Pre-1.0, not stable                                                     │
│                                                                              │
│   VERDICT: Tauri remains best choice for now                                │
│   ─────────────────────────────────────────                                 │
│   • xterm.js is battle-tested terminal emulator                             │
│   • Web tech is mature for complex UIs                                      │
│   • Pure Rust options lack terminal widget                                  │
│   • Revisit when Rust terminal ecosystem matures                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Cross-Platform Output Strategy

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    ONE CODEBASE → MULTIPLE TARGETS                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│                         ┌─────────────────────────┐                         │
│                         │      YOUR CODE          │                         │
│                         │   Rust + WGSL shaders   │                         │
│                         │   (using wgpu)          │                         │
│                         └───────────┬─────────────┘                         │
│                                     │                                        │
│               ┌─────────────────────┴─────────────────────┐                 │
│               ▼                                           ▼                 │
│      ┌─────────────────┐                        ┌─────────────────┐        │
│      │  cargo build    │                        │  wasm-pack      │        │
│      │  --release      │                        │  build --web    │        │
│      └────────┬────────┘                        └────────┬────────┘        │
│               │                                          │                  │
│               ▼                                          ▼                  │
│      ┌─────────────────┐                        ┌─────────────────┐        │
│      │  Native Binary  │                        │  WASM + JS glue │        │
│      │  (.exe / ELF)   │                        │  (.wasm + .js)  │        │
│      └────────┬────────┘                        └────────┬────────┘        │
│               │                                          │                  │
│               ▼                                          ▼                  │
│      ┌─────────────────┐                        ┌─────────────────┐        │
│      │  wgpu →         │                        │  wgpu →         │        │
│      │  • Vulkan       │                        │  • WebGPU       │        │
│      │  • Metal        │                        │  (in browser)   │        │
│      │  • DirectX 12   │                        │                 │        │
│      └─────────────────┘                        └─────────────────┘        │
│                                                                              │
│   SAME Rust code, SAME WGSL shaders, ZERO changes between targets           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 11. Alternative: Zed's GPUI Approach

### What is Zed?

Zed is a code editor built in 100% Rust with NO web technologies:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   ZED ARCHITECTURE                                              │
│                                                                  │
│   Language:    100% Rust                                        │
│   UI:          GPUI (custom GPU-accelerated framework)          │
│   Rendering:   Direct to GPU via Metal (macOS) / Vulkan (Linux)│
│   Web tech:    NONE - no HTML, CSS, JS, or browser engine       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### GPUI Framework

Zed built their own UI framework from scratch:

```
GPUI Features:
─────────────────────────────────────
• Direct GPU shader rendering
• Layout computed in Rust (not CSS)
• Custom font rasterization
• ~120fps UI updates
• Recently open-sourced as standalone crate
```

### Comparison: UI Tech Approaches

| Tool | UI Technology | Rendering | Effort |
|------|---------------|-----------|--------|
| VS Code | Electron (Chromium) | HTML/CSS/JS | Web skills |
| Tauri apps | System WebView | HTML/CSS/JS | Web skills |
| **Zed** | GPUI (custom) | Native GPU | Build everything |
| Neovim | Terminal | Text-based | Terminal |
| Sublime Text | Custom (C++) | OpenGL | Build everything |

### Tauri vs GPUI for Cloud Shell

| Aspect | Tauri (our choice) | GPUI (Zed's approach) |
|--------|-------------------|----------------------|
| **RAM** | ~50-80 MB | ~30-50 MB |
| **Performance** | Good | Excellent |
| **UI Development** | HTML/CSS/JS (fast) | Custom Rust (steep learning) |
| **Ecosystem** | Web libs (xterm.js, D3.js) | Build from scratch |
| **Cross-platform** | WebView abstraction | Platform-specific GPU |
| **Development speed** | Fast iteration | Slow, lots of code |
| **Team size** | Solo/small | Needs investment |

### Why Tauri for Cloud Shell (Not GPUI)

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   GPUI tradeoffs:                                               │
│   ─────────────────────────────────────────                     │
│   ✗ Must build entire UI system from scratch                    │
│   ✗ No existing terminal emulator (xterm.js won't work)        │
│   ✗ Custom layout engine (reimplementing CSS)                   │
│   ✗ Years of development to match web capability               │
│                                                                  │
│   Tauri advantages for our use case:                            │
│   ─────────────────────────────────────────                     │
│   ✓ xterm.js works out of the box (terminal emulation)         │
│   ✓ Existing UI libraries (charts, autocomplete)               │
│   ✓ Fast iteration with hot reload                              │
│   ✓ Web skills transfer directly                                │
│   ✓ 50-80 MB RAM is already efficient                          │
│                                                                  │
│   GPUI makes sense when:                                        │
│   ─────────────────────────────────────────                     │
│   • Building something like a code editor (120fps scrolling)    │
│   • Have team + funding for multi-year development              │
│   • Need absolute minimum latency                               │
│   • Don't need complex widgets (terminal, charts)               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Could GPUI Complement Cloud Shell?

Future possibility - hybrid approach:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   Potential hybrid (future exploration):                        │
│                                                                  │
│   • Main window: Tauri (HTML/CSS/JS)                            │
│   • Terminal pane: GPUI renderer (if they build one)            │
│   • Or: Use GPUI for ultra-responsive input line only          │
│                                                                  │
│   But for now: Tauri + xterm.js is the pragmatic choice        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 11. Deep Dive: Existing Projects

> Research conducted 2024-12-30

### A. WARP TERMINAL (Closest to Our Vision)

**Source:** [How Warp Works](https://www.warp.dev/blog/how-warp-works), [Warp Features](https://www.warp.dev/all-features)

```
┌─────────────────────────────────────────────────────────────────┐
│   WARP ARCHITECTURE                                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Language:     100% Rust                                       │
│   Rendering:    Custom GPU framework (Metal → wgpu)             │
│   UI:           Custom React-like system built from scratch     │
│   Performance:  >144 FPS, 1.9ms average redraw                  │
│   Code share:   98% between macOS and Linux                     │
│                                                                  │
│   Linux stack:  wgpu + winit + cosmic-text (System76)          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Key Features to Steal:**

| Feature | How Warp Does It | Our Approach |
|---------|------------------|--------------|
| **Blocks** | Groups cmd + output into atomic units | Same concept, HTML divs |
| **AI Mode** | `#` triggers AI, Claude/GPT backend | Same, local LLM option |
| **Agent Mode** | Autonomous multi-step execution | Same architecture |
| **Workflows** | Saved command sequences | Integrate with cloud_control |
| **Notebooks** | Reference docs for AI context | Our infra as context |

**What Warp Built From Scratch (why it took years):**
- Custom UI framework (like building a browser)
- Custom text editor (cursor movement, selection)
- Custom layout engine (reimplementing CSS)
- Custom font rasterization

**Lesson:** Warp proves the concept works. Their AI + blocks UX is exactly what we want. But they had VC funding and years of development for the custom UI. We use Tauri + xterm.js to get 80% of the result in 10% of the time.

---

### B. AMAZON Q CLI (née Fig)

**Source:** [GitHub](https://github.com/aws/amazon-q-developer-cli), [withfig/autocomplete](https://github.com/withfig/autocomplete)

```
┌─────────────────────────────────────────────────────────────────┐
│   AMAZON Q CLI ARCHITECTURE                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   fig_desktop:    Rust app using tao/wry (like Tauri!)         │
│   figterm:        Headless PTY interceptor                      │
│   q_cli:          CLI interface                                 │
│   Autocomplete:   React web apps in WebView                     │
│   Position:       macOS Accessibility API for cursor location   │
│                                                                  │
│   KEY INSIGHT: They use tao/wry (Tauri's foundation!)          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Key Features to Steal:**

| Feature | How Fig Does It | Our Approach |
|---------|-----------------|--------------|
| **Completion Specs** | Declarative JSON schemas | Same format, community specs |
| **Overlay Window** | Positioned over existing terminal | We ARE the terminal |
| **PTY Intercept** | figterm grabs edit buffer | Native in our Rust backend |
| **IDE Integration** | VSCode, JetBrains extensions | Future: VSCode extension |

**Massive Resource:** [withfig/autocomplete](https://github.com/withfig/autocomplete) has **completion specs for 600+ CLI tools**. We can use these directly!

**Lesson:** Fig/Amazon Q validates tao/wry (Tauri's core) for desktop apps. Their completion spec format is a community standard we should adopt.

---

### C. RIO TERMINAL

**Source:** [GitHub](https://github.com/raphamorim/rio), [rioterm.com](https://rioterm.com/)

```
┌─────────────────────────────────────────────────────────────────┐
│   RIO ARCHITECTURE                                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Language:     Rust + Tokio runtime                            │
│   Rendering:    Sugarloaf (custom renderer on wgpu)            │
│   ANSI Parser:  Forked from Alacritty's VTE                    │
│   GPU APIs:     Metal, Vulkan, DX11/12, OpenGL, WebGL          │
│   Platforms:    macOS, Linux, Windows, FreeBSD, Web (WASM)     │
│                                                                  │
│   State:        Redux-like state machine                        │
│   Optimization: Only redraw changed lines                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Key Features to Steal:**

| Feature | How Rio Does It | Our Approach |
|---------|-----------------|--------------|
| **VTE Parser** | Alacritty fork, battle-tested | Use same crate if native |
| **State Machine** | Redux pattern, selective redraw | Similar for xterm.js |
| **WebAssembly** | Same code runs in browser | Future: web version |
| **Sixel/iTerm2** | Image protocols | xterm.js addons |

**Lesson:** If we ever need native terminal parsing (Phase 4), Rio's Sugarloaf and Alacritty's VTE are the reference implementations.

---

### D. WEZTERM

**Source:** [GitHub](https://github.com/wezterm/wezterm), [wezterm.org](https://wezterm.org/)

```
┌─────────────────────────────────────────────────────────────────┐
│   WEZTERM ARCHITECTURE                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Language:     Rust                                            │
│   Rendering:    GPU-accelerated (OpenGL)                        │
│   Config:       Lua scripting (hot-reload)                      │
│   Multiplexer:  Built-in (like tmux, but native)               │
│   SSH:          Built-in SSH domains with auto-reconnect        │
│                                                                  │
│   Features:     Ligatures, true color, images, mouse, serial   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Key Features to Steal:**

| Feature | How WezTerm Does It | Our Approach |
|---------|---------------------|--------------|
| **SSH Domains** | Transparent remote sessions | cloud_control_lib::ssh |
| **Auto-reconnect** | Certificate-based resume | Same for our VMs |
| **Lua Config** | Runtime scriptable | Future: scripting layer |
| **Multiplexer** | Native tabs/panes/windows | HTML tabs, native in backend |

**Lesson:** WezTerm's SSH domain concept (connect to remote, auto-reconnect, resume) is exactly what we need for cloud VM sessions.

---

### E. TABBY + HYPER (What NOT to Do)

**Source:** [Tabby GitHub](https://github.com/Eugeny/tabby), [xterm.js](https://xtermjs.org/)

```
┌─────────────────────────────────────────────────────────────────┐
│   TABBY/HYPER ARCHITECTURE                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Framework:    Electron (bundles entire Chromium)              │
│   Terminal:     xterm.js + node-pty                             │
│   RAM:          150-300 MB                                      │
│   Startup:      Slow (Chromium init)                            │
│                                                                  │
│   BUT: Feature-rich, plugin system, SSH, serial, themes        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**What to Learn:**

| From Tabby | Our Approach |
|------------|--------------|
| Plugin architecture | Tauri plugins + command extensions |
| SSH connection manager | cloud_control_lib integration |
| Theme system | CSS variables, easy |
| Serial port support | Not needed for cloud |

**Lesson:** Tabby proves xterm.js + node-pty works well. But Electron is too heavy. Tauri gives us the same WebView capability at 1/3 the RAM.

---

### F. GPUI (Zed's Framework)

**Source:** [gpui.rs](https://www.gpui.rs/), [crates.io](https://crates.io/crates/gpui), [gpui-component](https://github.com/longbridge/gpui-component)

```
┌─────────────────────────────────────────────────────────────────┐
│   GPUI STANDALONE USAGE                                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Install:      cargo add gpui                                  │
│   Version:      0.2.2 (pre-1.0, breaking changes expected)     │
│   License:      Apache 2.0                                      │
│   Platforms:    macOS (Metal), Linux (Vulkan)                  │
│                                                                  │
│   Style:        Tailwind-like API in Rust                       │
│   State:        Entity system (like ECS)                        │
│   Testing:      Built-in test context                           │
│                                                                  │
│   Community:    gpui-component (60+ widgets)                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**How We Could Use GPUI:**

```
OPTION A: Replace Tauri entirely with GPUI
───────────────────────────────────────────
• Maximum performance
• No WebView overhead
• BUT: No xterm.js, must build terminal from scratch
• BUT: Pre-1.0, breaking changes
• BUT: Steep learning curve

OPTION B: Hybrid - GPUI for specific components
───────────────────────────────────────────
• Main window: Tauri (HTML/CSS)
• Input line: GPUI (ultra-responsive)
• Autocomplete: GPUI (instant rendering)
• Terminal output: xterm.js

OPTION C: Future migration path
───────────────────────────────────────────
• Start with Tauri + xterm.js (fast to build)
• Profile performance bottlenecks
• Replace specific slow parts with GPUI
• Eventually full GPUI if justified
```

**Realistic Assessment:**

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   GPUI is exciting but RISKY for us because:                   │
│                                                                  │
│   ✗ Pre-1.0 with breaking changes                               │
│   ✗ No terminal emulator component                              │
│   ✗ Would need to build xterm.js equivalent in Rust            │
│   ✗ Documentation is sparse (read Zed source)                  │
│   ✗ Windows support unclear                                     │
│                                                                  │
│   GPUI makes sense when:                                        │
│                                                                  │
│   ✓ Building next Zed (code editor, not terminal)              │
│   ✓ Need absolute minimum latency                               │
│   ✓ Have time to build custom widgets                          │
│   ✓ Okay with macOS/Linux only initially                       │
│                                                                  │
│   VERDICT: Watch GPUI, don't adopt yet                         │
│            Revisit when 1.0 releases                            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### Summary: What to Steal from Each

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   FROM WARP:                                                    │
│   ─────────────────────────────────────────────                 │
│   • Blocks concept (cmd + output as unit)                       │
│   • AI mode with # trigger                                      │
│   • Agent mode for multi-step tasks                             │
│   • Workflows (saved command sequences)                         │
│                                                                  │
│   FROM AMAZON Q / FIG:                                          │
│   ─────────────────────────────────────────────                 │
│   • tao/wry architecture (validates Tauri choice)              │
│   • Completion spec format (600+ CLI tools!)                   │
│   • PTY intercept pattern                                       │
│                                                                  │
│   FROM RIO:                                                     │
│   ─────────────────────────────────────────────                 │
│   • VTE parser if we go native                                  │
│   • Redux state pattern                                         │
│   • WebAssembly target possibility                              │
│                                                                  │
│   FROM WEZTERM:                                                 │
│   ─────────────────────────────────────────────                 │
│   • SSH domains (transparent remote)                            │
│   • Auto-reconnect with certificates                            │
│   • Multiplexer architecture                                    │
│                                                                  │
│   FROM TABBY:                                                   │
│   ─────────────────────────────────────────────                 │
│   • xterm.js + node-pty integration patterns                   │
│   • Plugin architecture ideas                                   │
│                                                                  │
│   FROM GPUI:                                                    │
│   ─────────────────────────────────────────────                 │
│   • Watch for 1.0 release                                       │
│   • Potential future migration path                             │
│   • Tailwind-in-Rust style API inspiration                     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### Revised Development Path

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   PHASE 1: MVP (Tauri + xterm.js)                              │
│   ─────────────────────────────────────────────                 │
│   • Tauri app with xterm.js                                     │
│   • Basic command execution                                     │
│   • Warp-style blocks (HTML divs)                              │
│   • Use Fig's completion specs (600+ tools free!)              │
│                                                                  │
│   PHASE 2: Cloud Integration                                    │
│   ─────────────────────────────────────────────                 │
│   • WezTerm-style SSH domains                                   │
│   • Connect to your VMs transparently                          │
│   • Auto-reconnect on network issues                           │
│   • cloud_control_lib integration                              │
│                                                                  │
│   PHASE 3: AI Features                                          │
│   ─────────────────────────────────────────────                 │
│   • Warp-style # trigger for AI                                 │
│   • Natural language → commands                                 │
│   • Context: your VMs, services, history                       │
│   • Agent mode for multi-step tasks                             │
│                                                                  │
│   PHASE 4: Polish                                               │
│   ─────────────────────────────────────────────                 │
│   • Workflows (saved sequences)                                 │
│   • Notifications (system tray)                                 │
│   • Themes and customization                                    │
│                                                                  │
│   PHASE 5 (Future): Performance                                 │
│   ─────────────────────────────────────────────                 │
│   • Profile bottlenecks                                         │
│   • Consider GPUI for specific components                       │
│   • Native VTE parser if needed                                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 13. Visual Documentation

See the Obsidian canvas for interactive diagrams:

```
0.spec/
├── BRAINSTORM.md                    # This file
└── CloudShell_Architecture.canvas   # Visual diagrams
```

**Canvas Contents:**
- **Architecture Diagram** - Full stack from user input to system layer
- **UI Mockups** - Terminal view, autocomplete, AI mode, SSH sessions
- **Technology Choices** - Why Tauri, why xterm.js
- **Rendering Stack Options** - Current vs Pure Rust vs GPUI

---

## 14. Open Questions

- [ ] Local LLM vs API for AI features? (Ollama, llama.cpp?)
- [ ] Plugin system for custom commands?
- [ ] Sync settings across devices?
- [ ] Mobile companion app? (Flutter? React Native?)
- [ ] Integration with VS Code terminal?
- [ ] Explore GPUI for specific high-performance components?
- [ ] Study Warp's block-based output approach?
