// ── SuperApp Routes — per-user full-config artifact ──
//
// GET /superapp/config/:user
//   Public URL: https://api.diegonmarcos.com/pub/superapp/config/<user>
//   (Caddy's `handle_path /pub/*` strips the prefix, so the app sees
//   /superapp/config/<user> — same convention as every other route here.)
//
// AUTH: none in-app, by design. This path is NOT in build.json's
// proxy.primary.public_paths[], so Caddy's mkProtected gate applies: a request
// carrying `Authorization: Bearer *` is validated by introspect-proxy against
// Authelia and proxied on; anything else is redirected to the Authelia portal.
// No new auth mechanism, matching the existing /pub/mail/* posture.
//
// WHY THIS ENDPOINT IS PUBLIC+BEARER RATHER THAN WG-ONLY: the artifact contains
// the phone's WireGuard configuration, so it must be fetchable BEFORE the phone
// can join the mesh. A wg-only route is unreachable at exactly that moment.
//
// The artifact carries NO WireGuard private key (`_meta.secrets_included:
// false`) — the key is the device's own identity and never traverses the
// network. See 1_cloud-configs/src/derive/cloud-data-config-derive.ts.
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import type { FastifyInstance } from "fastify";

// The artifact is generated into 1_cloud-configs/dist/ and reaches the image as
// a symlink under src/code/ that CI resolves to a real file before the build
// (Dockerfile.native does `COPY code /app`, so it lands beside the app).
// The repo-relative candidate keeps `npm run dev` working from a checkout.
const CANDIDATE_DIRS = [
  process.cwd(),
  join(process.cwd(), "../../../../1_cloud-configs/dist"),
];

// Slug guard: the user segment is interpolated into a filename, so anything
// that is not a plain slug is rejected before it can reach the filesystem.
const SLUG = /^[a-z0-9][a-z0-9_-]*$/;

export async function registerSuperapp(app: FastifyInstance) {
  app.get<{ Params: { user: string } }>(
    "/superapp/config/:user",
    {
      schema: {
        tags: ["SuperApp"],
        params: {
          type: "object" as const,
          properties: { user: { type: "string" as const } },
          required: ["user"],
        },
      },
    },
    async (req, reply) => {
      const user = req.params.user;
      if (!SLUG.test(user)) {
        reply.code(400).send({ error: "Invalid user slug" });
        return;
      }

      const file = `build-cloud-superapp-${user}.json`;
      const path = CANDIDATE_DIRS.map((d) => join(d, file)).find((p) => existsSync(p));
      if (!path) {
        reply.code(404).send({ error: `No SuperApp config for user: ${user}` });
        return;
      }

      reply.type("application/json").send(readFileSync(path, "utf-8"));
    },
  );
}
