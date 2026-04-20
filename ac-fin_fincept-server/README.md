# ac-fin_fincept-server

Backend-only deployment of the Fincept Terminal Rust port.

- **Source**: `~/git/others/fincept-rs/` (read-only from here — build context is relative per `build.json`)
- **Binary**: `crates/server` → `fincept-server`
- **Container**: `ghcr.io/diegonmarcos/fincept-server:latest`
- **Port**: 8340 (internal) → Caddy proxy at `fincept-api.diegonmarcos.com`
- **Auth**: Authelia default (bypassable per call with bearer token)
- **Health**: `GET /health`

## Endpoints

```
GET  /health
GET  /api/v1/info
GET  /api/v1/personas
POST /api/v1/personas/:id/score
GET  /api/v1/topics
POST /api/v1/topics/:topic/publish
GET  /api/v1/topics/:topic/peek
GET  /api/v1/mcp/tools
POST /api/v1/mcp/tools/:name/call
GET  /api/v1/ws              # WebSocket — {op:subscribe|publish|ping}
```

## Deploy

```bash
cd ~/git/cloud/a_solutions/ac-fin_fincept-server
./build.sh all      # nix + secrets  (safe)
./build.sh ship     # nix + secrets + rsync + compose  (TOUCHES VM — ask first)
```

Frontends (desktop egui, WASM web) consume this via `fincept-client` → do
not call library crates directly. Adding a new endpoint = add a route to
`crates/server/src/routes/` + a method to `crates/client/src/lib.rs`.
