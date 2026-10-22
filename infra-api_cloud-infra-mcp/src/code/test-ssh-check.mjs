// ssh_check must probe exactly what ssh_exec uses: same alias (mesh via
// ~/.ssh/config), same options, same wrapper; never the public ip.
// Run: node --experimental-strip-types test-ssh-check.mjs
import assert from "node:assert/strict";
import { sshArgv, vmMeshAddress } from "./shared/libs/ssh-argv.ts";

const vm = { ip: "129.151.228.66", wg_ip: "10.0.0.4" };
assert.equal(vmMeshAddress(vm), "10.0.0.4");
assert.equal(vmMeshAddress({ ip: "1.2.3.4" }), "1.2.3.4");

const exec = sshArgv("oci-analytics", "bash -c uptime");
const check = sshArgv("oci-analytics", "bash -c echo");
assert.deepEqual(check.slice(0, -1), exec.slice(0, -1), "check/exec differ in options or target");
assert.ok(check.includes("oci-analytics"));
assert.ok(!check.join(" ").includes(vm.ip), "probe must not use the public ip");
assert.ok(check.includes("ConnectTimeout=10"));
console.log("ok");
