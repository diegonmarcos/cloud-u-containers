# PhotoPrism Photo Gallery

AI-powered photo management with OCI Object Storage backend.

## Architecture

- **PhotoPrism** — Web UI and AI indexing engine
- **MariaDB** — Metadata database
- **Rclone** — FUSE mount for OCI Object Storage (S3-compatible)

## Storage Pipeline

Photos are stored in OCI Object Storage (`my-photos` bucket) and mounted via rclone's FUSE driver with VFS caching. PhotoPrism accesses them read-only for indexing and serving.

## Access

Protected by Authelia 2FA. Root path redirects to the landing page at `diegonmarcos.github.io/myphotos/`.
