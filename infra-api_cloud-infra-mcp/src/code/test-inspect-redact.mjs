// devops.docker.inspect / devops.ssh.ps must never print a secret passed as a
// command-line argument. Incident 2026-10-10: kg-store ran
// `surreal start --user root --pass <pw>` and inspect printed Config.Cmd as is.
// Run: node --experimental-strip-types test-inspect-redact.mjs
import assert from "node:assert/strict";
import { redactArgv, redactCommandString, redactInspectArgv, REDACTED } from "./shared/libs/redact-argv.ts";

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`ok - ${name}`); };
const S = "Zx9secretValue42";          // a fake secret; must never survive
const none = (v) => assert.ok(!JSON.stringify(v).includes(S), `leaked: ${JSON.stringify(v)}`);

t("surreal --pass as separate argv word", () => {
  const r = redactArgv(["start", "--log", "info", "--user", "root", "--pass", S, "--bind", "127.0.0.1:8001", "file:/data/surreal.db"]);
  none(r);
  assert.deepEqual(r.slice(4, 8), ["root", "--pass", REDACTED, "--bind"]);
  assert.equal(r[8], "127.0.0.1:8001");
});
t("compose string command (one word with spaces)", () => {
  const r = redactArgv([`start --log info --user root --pass ${S} --bind 127.0.0.1:8001 file:/data/surreal.db`]);
  none(r); assert.match(r[0], /--pass \*\*\*REDACTED\*\*\* --bind/);
});
t("--password=, --token=, --api-key=, --secret", () => {
  for (const f of ["--password=", "--token=", "--api-key=", "--client-secret=", "-password="]) {
    const r = redactArgv([f + S]); none(r); assert.equal(r[0], f + REDACTED);
  }
  none(redactArgv(["--token", S])); none(redactArgv(["--secret", S])); none(redactArgv(["--access-key", S]));
});
t("-p <secret> redacted, -p <port> kept", () => {
  none(redactArgv(["mysql", "-u", "root", "-p", S]));
  assert.deepEqual(redactArgv(["serve", "-p", "8080"]), ["serve", "-p", "8080"]);
  assert.deepEqual(redactArgv(["-p", "10.0.0.6:3101"]).length, 2);
  assert.deepEqual(redactArgv(["-p", "53/udp"]), ["-p", "53/udp"]);
});
t("mysql-style attached -pSECRET", () => {
  const r = redactArgv(["mysql", "-uroot", `-p${S}`]); none(r); assert.equal(r[2], `-p${REDACTED}`);
  assert.deepEqual(redactArgv(["tar", "-pv"]), ["tar", "-pv"]);
});
t("URL credentials", () => {
  const r = redactArgv(["--db", `postgres://app:${S}@localhost:5432/db`, `https://u:${S}@example.com/x`]);
  none(r); assert.match(r[1], /^postgres:\/\/app:\*\*\*REDACTED\*\*\*@localhost:5432\/db$/);
});
t("sh -c script with inline flags and env assignments", () => {
  const r = redactArgv(["sh", "-c", `exec env KG_STORE_PASS="${S}" DB_PASSWORD=${S} npx tsx index.ts --token '${S}'`]);
  none(r); assert.match(r[2], /npx tsx index\.ts/);
  // a $VAR reference is harmless either way, but the name stays readable
  assert.match(redactCommandString('env KG_STORE_PASS="$KG_STORE_PASS_PUB" npx'), /KG_STORE_PASS=/);
});
t("ps line (devops.ssh.ps)", () => {
  const line = `  1234 01:02:03 /surreal start --user root --pass ${S} --bind 127.0.0.1:8002`;
  const r = redactCommandString(line); none(r); assert.match(r, /^  1234 01:02:03 \/surreal start/);
});
t("harmless commands unchanged", () => {
  const argv = ["/init"], b = ["node", "server.js", "--port", "3000", "--log-level", "info"];
  assert.deepEqual(redactArgv(argv), argv); assert.deepEqual(redactArgv(b), b);
  assert.equal(redactCommandString("caddy run --config /etc/caddy/Caddyfile"), "caddy run --config /etc/caddy/Caddyfile");
});
t("whole docker-inspect object: Args, Cmd, Entrypoint, Healthcheck, Labels", () => {
  const item = {
    Path: "/surreal",
    Args: ["start", "--pass", S],
    Config: {
      Cmd: ["start", "--user", "root", "--pass", S],
      Entrypoint: ["/bin/sh", "-c", `run --password=${S}`],
      Healthcheck: { Test: ["CMD", "curl", `http://u:${S}@127.0.0.1/health`] },
      Labels: { "x.cmd": `start --pass ${S}` },
      Env: ["A=1"],
    },
  };
  redactInspectArgv(item); none(item);
  assert.equal(item.Path, "/surreal"); assert.deepEqual(item.Config.Env, ["A=1"]);
});

console.log(`# ${n} passed`);
