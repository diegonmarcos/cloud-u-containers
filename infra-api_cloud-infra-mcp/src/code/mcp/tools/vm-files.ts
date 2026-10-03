// ── devops.vm.read_file / read_tree / write_file + devops.docker.env_tz ──
// Bounded file access on a VM or a container on it. Reads are read-only and
// pass a secret deny-list (shared/libs/vm-files-policy.ts) checked on both the
// given path and its remote realpath. The one write tool only lands under a
// declared work root and every attempt — refused or not — is audited.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sshExec } from "../../shared/libs/ssh.js";
import { resolveVmId } from "../../shared/libs/config.js";
import { audit } from "../../shared/libs/audit.js";
import {
  READ_FILE_DEFAULT_BYTES, READ_FILE_MAX_BYTES, READ_TREE_DEFAULT_BYTES, READ_TREE_MAX_BYTES,
  WRITE_FILE_MAX_BYTES, TREE_EXCLUDES, WRITE_ROOTS,
  readDenied, treeDenied, writeTarget, looksText, envLine, shq,
} from "../../shared/libs/vm-files-policy.js";

const CONTAINER_RE = /^[a-zA-Z0-9_.-]+$/;

type Out = { content: { type: "text"; text: string }[]; isError?: boolean };
const err = (text: string): Out => ({ content: [{ type: "text", text }], isError: true });

/**
 * Wrap a shell snippet so it runs on the VM, or inside `container` on it.
 * The snippet travels base64 (alphabet has no quotes): the remote LOGIN shell
 * is fish on some VMs, and fish treats \' inside single quotes as an escape,
 * so nested '\'' quoting of paths breaks there. Decoding on the far side means
 * no shell but bash/sh ever parses the snippet.
 */
function where(snippet: string, container?: string, user?: string, stdin = false): string {
  const b64 = Buffer.from(snippet, "utf8").toString("base64");
  const decoded = `"$(echo ${b64} | base64 -d)"`;
  if (!container) return `sh -c ${decoded}`;
  if (!CONTAINER_RE.test(container) || (user && !CONTAINER_RE.test(user))) throw new Error("invalid container/user name");
  return `docker exec${stdin ? " -i" : ""}${user ? ` -u ${user}` : ""} ${container} sh -c ${decoded}`;
}

/** Remote realpath + type + size; refuses before any content is read. */
function stat(vmId: string, path: string, container?: string) {
  const r = sshExec(vmId, where(`p=$(readlink -f ${shq(path)}) && [ -e "$p" ] && printf '%s\\n' "$p" && stat -c '%F|%s' "$p" || { echo "no such file: ${path.replace(/[^A-Za-z0-9_./ -]/g, "?")}" >&2; exit 1; }`, container), 15_000);
  if (!r.ok) return { ok: false as const, why: (r.stderr || r.stdout).trim() || `exit ${r.exitCode}` };
  const [real, info] = r.stdout.trim().split("\n");
  const [type, size] = (info ?? "").split("|");
  return { ok: true as const, real, type, size: Number(size) };
}

export function registerVmFilesTools(server: McpServer) {
  server.tool(
    "devops.vm.read_file",
    "Read ONE file on a VM, or inside a container on it (read-only). Refuses secrets (/run/secrets, *.secrets, secrets/ dirs, ~/.ssh, sops/age keys, *.pem/*.key, .env, /proc, /etc/shadow), checked on the path AND its realpath. Returns text, or base64 for binary. Capped (default 64 KiB, max 512 KiB); says when truncated.",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      path: z.string().describe("Absolute file path (on the VM, or inside the container when given)"),
      container: z.string().regex(CONTAINER_RE).optional().describe("Container name — read inside it via docker exec"),
      max_bytes: z.number().int().min(1).max(READ_FILE_MAX_BYTES).optional().describe(`Byte cap (default ${READ_FILE_DEFAULT_BYTES}, max ${READ_FILE_MAX_BYTES})`),
    },
    async ({ vm, path, container, max_bytes }) => {
      const vmId = resolveVmId(vm);
      const deny = readDenied(path);
      if (deny) return err(`${path}: ${deny}`);
      const s = stat(vmId, path, container);
      if (!s.ok) return err(`${path}: ${s.why}`);
      const denyReal = readDenied(s.real);
      if (denyReal) return err(`${path} -> ${s.real}: ${denyReal}`);
      if (!/regular/.test(s.type)) return err(`${s.real} is a ${s.type}, not a regular file (use devops.vm.read_tree for directories)`);
      const cap = max_bytes ?? READ_FILE_DEFAULT_BYTES;
      const r = sshExec(vmId, where(`head -c ${cap} ${shq(s.real)} | base64 -w0`, container), 30_000);
      if (!r.ok) return err(`read failed: ${(r.stderr || r.stdout).trim()}`);
      const buf = Buffer.from(r.stdout.trim(), "base64");
      const truncated = s.size > buf.length;
      const loc = `${container ? `${container}@` : ""}${vmId}:${s.real}`;
      const head = `${loc}  (${s.size} bytes${truncated ? `, TRUNCATED to first ${buf.length}` : ""})`;
      const body = looksText(buf)
        ? `${head}\n--- text ---\n${buf.toString("utf8")}`
        : `${head}\n--- base64 (binary) ---\n${buf.toString("base64")}`;
      return { content: [{ type: "text", text: body }] };
    },
  );

  server.tool(
    "devops.vm.read_tree",
    "Read a DIRECTORY on a VM, or inside a container on it, as a gzip tarball returned base64 (read-only). Secret paths are excluded from the archive (secrets/, *.secrets, .ssh, sops, keys, .env, *.pem/*.key …) and roots like /, /etc, /home, /root, /proc are refused. Capped (default 1 MiB, max 4 MiB compressed); refuses rather than returning a cut tarball.",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      path: z.string().describe("Absolute directory path"),
      container: z.string().regex(CONTAINER_RE).optional().describe("Container name — read inside it via docker exec"),
      max_bytes: z.number().int().min(1).max(READ_TREE_MAX_BYTES).optional().describe(`Compressed byte cap (default ${READ_TREE_DEFAULT_BYTES}, max ${READ_TREE_MAX_BYTES})`),
      list_only: z.boolean().optional().describe("Return only the file list (tar tv) instead of the tarball"),
    },
    async ({ vm, path, container, max_bytes, list_only }) => {
      const vmId = resolveVmId(vm);
      const deny = treeDenied(path);
      if (deny) return err(`${path}: ${deny}`);
      const s = stat(vmId, path, container);
      if (!s.ok) return err(`${path}: ${s.why}`);
      const denyReal = treeDenied(s.real);
      if (denyReal) return err(`${path} -> ${s.real}: ${denyReal}`);
      if (!/directory/.test(s.type)) return err(`${s.real} is a ${s.type}, not a directory (use devops.vm.read_file)`);
      const cap = max_bytes ?? READ_TREE_DEFAULT_BYTES;
      const ex = TREE_EXCLUDES.map((p) => `--exclude=${shq(p)}`).join(" ");
      const tar = `tar -C ${shq(s.real)} ${ex} -czf - . 2>/dev/null`;
      const loc = `${container ? `${container}@` : ""}${vmId}:${s.real}`;
      if (list_only) {
        const r = sshExec(vmId, where(`${tar} | tar -tzvf - | head -n 2000`, container), 60_000);
        if (!r.stdout.trim()) return err(`list failed: ${(r.stderr || r.stdout).trim() || `exit ${r.exitCode}`}`);
        return { content: [{ type: "text", text: `${loc} (secret paths excluded)\n${r.stdout.trim()}` }] };
      }
      // +1 byte tells us the archive did not fit.
      const r = sshExec(vmId, where(`${tar} | head -c ${cap + 1} | base64 -w0`, container), 120_000);
      const buf = Buffer.from(r.stdout.trim(), "base64");
      if (!buf.length) return err(`read_tree failed: ${(r.stderr || "").trim() || `exit ${r.exitCode}`}`);
      if (buf.length > cap) return err(`${loc}: compressed tree exceeds ${cap} bytes — narrow the path, raise max_bytes (max ${READ_TREE_MAX_BYTES}), or use list_only`);
      return { content: [{ type: "text", text: `${loc}  tar.gz ${buf.length} bytes (secret paths excluded)\n--- base64 ---\n${buf.toString("base64")}` }] };
    },
  );

  server.tool(
    "devops.vm.write_file",
    `WRITE one file — ONLY under a declared work root (${WRITE_ROOTS.map((r) => `${r.container}@${r.vm}:${r.root}`).join(", ")}); anything else is refused. Writes as the root's owner user, creates parent dirs inside the root, refuses symlink escapes, will not overwrite an existing file unless overwrite=true. Max ${WRITE_FILE_MAX_BYTES} bytes. Every attempt is recorded in the audit log (obs.debug.db_audit).`,
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().regex(CONTAINER_RE).describe("Container holding the work root"),
      path: z.string().describe("Absolute file path under the work root"),
      content: z.string().describe("File content (UTF-8 text, or base64 when encoding=base64)"),
      encoding: z.enum(["utf8", "base64"]).optional().describe("Encoding of content (default utf8)"),
      overwrite: z.boolean().optional().describe("Replace an existing file (default false: refuse)"),
    },
    async ({ vm, container, path, content, encoding, overwrite }) => {
      const vmId = resolveVmId(vm);
      const target = `${container}@${vmId}:${path}`;
      // WRITE_ROOTS names VMs by alias; resolveVmId returns the canonical id.
      const vmKey = WRITE_ROOTS.find((r) => { try { return resolveVmId(r.vm) === vmId; } catch { return false; } })?.vm ?? vmId;
      const t = writeTarget(vmKey, container, path);
      if (!t.ok) {
        audit("devops.vm.write_file", target, `REFUSED ${t.why}`);
        return err(`${target}: ${t.why}`);
      }
      const data = encoding === "base64" ? Buffer.from(content, "base64") : Buffer.from(content, "utf8");
      if (data.length > WRITE_FILE_MAX_BYTES) {
        audit("devops.vm.write_file", target, `REFUSED ${data.length} bytes > cap`);
        return err(`${target}: ${data.length} bytes exceeds the ${WRITE_FILE_MAX_BYTES}-byte cap`);
      }
      const p = t.path;
      const dir = p.slice(0, p.lastIndexOf("/")) || "/";
      // Inside the container: create the parent, then re-check where it REALLY
      // is (a symlinked component could point out of the root), refuse a
      // symlink at the target, honour overwrite, then write from stdin.
      const script = [
        "set -e",
        `mkdir -p ${shq(dir)}`,
        `rd=$(readlink -f ${shq(dir)}); [ -d "$rd" ] || exit 10`,
        `case "$rd" in ${shq(t.root.root)}|${shq(t.root.root)}/*) ;; *) exit 11;; esac`,
        `if [ -L ${shq(p)} ]; then exit 12; fi`,
        overwrite ? ":" : `if [ -e ${shq(p)} ]; then exit 13; fi`,
        `base64 -d > ${shq(p)}`,
        `stat -c %s ${shq(p)}`,
      ].join("\n");
      const cmd = `echo ${data.toString("base64")} | ${where(script, container, t.root.user, true)}`;
      const r = sshExec(vmId, cmd, 30_000);
      if (!r.ok) {
        const codes: Record<number, string> = { 10: "parent dir unresolvable", 11: "parent resolves outside the work root", 12: "target is a symlink", 13: "file exists (pass overwrite=true)" };
        const why = codes[r.exitCode] ?? ((r.stderr || r.stdout).trim().slice(0, 200) || `exit ${r.exitCode}`);
        audit("devops.vm.write_file", target, `FAILED ${why}`);
        return err(`${target}: ${why}`);
      }
      audit("devops.vm.write_file", target, `OK ${r.stdout.trim()} bytes${overwrite ? " (overwrite)" : ""}`);
      return { content: [{ type: "text", text: `wrote ${r.stdout.trim()} bytes to ${target} (audited)` }] };
    },
  );

  server.tool(
    "devops.docker.env_tz",
    "Read-only timezone + environment view of a container: TZ, /etc/timezone, /etc/localtime target and `date` inside the container vs the host, plus its env var NAMES (values shown only for harmless keys like TZ/LANG/PATH/NODE_ENV; everything else masked).",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().regex(CONTAINER_RE).describe("Container name"),
    },
    async ({ vm, container }) => {
      const vmId = resolveVmId(vm);
      const env = sshExec(vmId, `docker inspect --format '{{json .Config.Env}}' ${shq(container)}`, 15_000);
      if (!env.ok) return err(`inspect failed: ${(env.stderr || env.stdout).trim()}`);
      let vars: string[] = [];
      try { vars = JSON.parse(env.stdout.trim()) ?? []; } catch { /* keep empty */ }
      const inner = sshExec(vmId, where(`echo "date:      $(date '+%Y-%m-%d %H:%M:%S %Z %z')"; echo "date -u:   $(date -u '+%Y-%m-%d %H:%M:%S %Z')"; echo "TZ:        \${TZ:-(unset)}"; echo "timezone:  $(cat /etc/timezone 2>/dev/null || echo '(none)')"; echo "localtime: $(readlink /etc/localtime 2>/dev/null || ([ -e /etc/localtime ] && echo '(regular file)') || echo '(none)')"`, container), 15_000);
      const host = sshExec(vmId, `echo "date:      $(date '+%Y-%m-%d %H:%M:%S %Z %z')"; echo "timezone:  $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"`, 15_000);
      const text = [
        `${container}@${vmId}`,
        "── inside container ──",
        inner.ok ? inner.stdout.trim() : `(exec failed: ${(inner.stderr || inner.stdout).trim()})`,
        "── host ──",
        host.stdout.trim(),
        `── env (${vars.length}, values masked unless harmless) ──`,
        ...vars.map(envLine).sort(),
      ].join("\n");
      return { content: [{ type: "text", text }] };
    },
  );
}
