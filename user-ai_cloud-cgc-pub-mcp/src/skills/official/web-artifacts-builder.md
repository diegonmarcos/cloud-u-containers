---
id: skill-web-artifacts
type: skill
name: "Web Artifacts Builder"
path: web-artifacts-builder
summary: "React + Tailwind + shadcn/ui"
category: Development
source: anthropics/skills
requiredMcp:
  - Write
  - Bash
parameters:
  - name: "init-artifact.sh"
    type: Script
    required: true
    description: "Initialize React project with all deps"
  - name: "bundle-artifact.sh"
    type: Script
    required: true
    description: "Parcel bundle to single HTML"
  - name: "Node 18+"
    type: Runtime
    required: true
    description: "Required for Vite version pinning"
---

Build elaborate multi-component artifacts: React 18 + TypeScript + Vite + Parcel bundling + Tailwind CSS + 40+ shadcn/ui components. Init --> Edit --> Bundle to single bundle.html. Avoid "AI slop" (centered layouts, purple gradients, rounded corners).

The workflow begins by running `init-artifact.sh` to scaffold a React project with all dependencies pre-installed, including Tailwind CSS, shadcn/ui components, Lucide icons, and Recharts. Development happens through direct file editing of components and pages. When the artifact is ready, `bundle-artifact.sh` uses Parcel to produce a single self-contained `bundle.html` file suitable for embedding or sharing. The skill explicitly warns against generic "AI slop" patterns -- centered hero sections, purple-to-blue gradients, excessive border-radius, and predictable card grids.

## Example

- "Build an interactive data explorer with filterable tables, charts, and a sidebar navigation using shadcn/ui"
- "Create a single-page Kanban board with drag-and-drop columns, bundled into one HTML file"
- "Scaffold a multi-step form wizard with validation, progress indicators, and toast notifications"
- "Build a real-time markdown editor with split preview pane, syntax highlighting, and export to HTML"
