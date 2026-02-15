# Front-End Developer Senior

**Brief**: Develops and maintains the 32-project front-end monorepo — TypeScript strict mode, Svelte 5 runes, Vue 3 composition API, SCSS/ITCSS. Manages build system (build.sh + build.json), dev servers, GitHub Pages CI/CD pipeline.

**Skill file**: `~/git/front/b_Work_Tools/skills_mcp/0.spec/skills.md` (frontend-developer persona)

**MCPs used**: `cloud-infra`

## APIs

| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Front tools | `front_list_projects`, `front_get_project`, `front_build`, `front_dev_server`, `front_deploy` |
| MCP | Repo tools | `read_file`, `search_repos` (front repo) |
| Direct | Matomo | `analytics.diegonmarcos.com/js/container_odwLIyPV.js` (tracking) |
| Direct | GitHub Actions | `.github/workflows/deploy.yml` (conditional per-project builds) |
| Direct | GitHub Pages | `diegonmarcos.github.io/*` (deployment target) |
| Direct | NocoDB | `db.diegonmarcos.com` (data backend for some projects) |
| Direct | PhotoPrism | `photos.diegonmarcos.com/api/v1/` (photo data for myphotos) |
