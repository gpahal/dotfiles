#!/bin/bash
set -euo pipefail
# serial

# The Stream Deck plugin's stats.js reads vm_stat, vm.swapusage, ps, and netstat output as
# Activity Monitor counts them, and draws each stat key as an SVG, with a placeholder when a stat
# is missing. Its sampler survives macmon failing to start, ignores a stopped macmon that exits
# late, backs off from one that keeps exiting or whose spawn throws, notices macmon once it's
# installed, and starts the sparklines afresh after a reset, and a kind's rate and sparkline once
# it's needed again. Fixed command output stands in for the real machine's, and a
# fake spawn for macmon, apart from one real spawn of a file that isn't executable.
# plugin.js drops a New Tab press while the last one's open-in still runs, as the Hammerspoon
# hotkey does, and runs it again once that one exits. A key whose render throws shows a
# placeholder, logged once, while the others update. A fake Stream Deck socket and open-in stand
# in for the real ones.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v node &> /dev/null || skip "node isn't installed"
STATS="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/stats.js"

# Run JavaScript with stats.js as `s`, and print what it prints
js() {
    node -e "const s = require(process.argv[1]); $1" "$STATS"
}

# Memory used: anonymous less purgeable, plus wired and compressed, in 16 KB pages
vm_stat='Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   194180.
Pages wired down:                             286445.
Pages purgeable:                               42444.
Anonymous pages:                             1113919.
Pages occupied by compressor:                 200796.'
assert_eq "$(((1113919 - 42444 + 286445 + 200796) * 16384))" \
    "$(VM_STAT="$vm_stat" js 'console.log(s.parseVmStat(process.env.VM_STAT))')" "memory used"

assert_eq '{"used":571211776,"total":2147483648}' \
    "$(js 'console.log(JSON.stringify(s.parseSwap("total = 2048.00M  used = 544.75M  free = 1503.25M  (encrypted)")))')" \
    "swap"

# Only en interfaces' link rows count, including one without an address, and one that's down (en5*),
# whose counters would otherwise come back as one burst when it's up again
netstat='Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
lo0        16384 <Link#1>                      100     0       5000      100     0       5000     0
en0        1500  <Link#11>   36:53:3e:4a:e9:c0     10     0       1000       20     0        200     0
en0        1500  192.168.1     192.168.1.5          10     -       1000       20     -        200     -
en3        1500  <Link#5>                            1     0         30        2     0          4     0
en5*       1500  <Link#7>    36:53:3e:4a:e9:c1      1     0       5000        1     0        600     0
utun4      1380  <Link#20>                          10     0        900       10     0        100     0'
assert_eq '{"rx":6030,"tx":804}' \
    "$(NETSTAT="$netstat" js 'console.log(JSON.stringify(s.parseNetstat(process.env.NETSTAT)))')" "network"

assert_eq '{"cpu":26.6,"name":"Activity Monitor"}' \
    "$(js 'console.log(JSON.stringify(s.parseTop(" 26.6 Activity Monitor\n 13.0 syspolicyd\n")))')" "top process"
assert_eq "null" "$(js 'console.log(s.parseTop(""))')" "top process with no output"

assert_eq "0 B 999 B 1.5 KB 120 MB 1.0 GB" \
    "$(js 'console.log([0, 999, 1500, 120e6].map((b) => s.formatBytes(b)).join(" "), s.formatBytes(1024 ** 3, 1024))')" \
    "byte formatting"

# Each key draws its stat, or a dash when it's missing
render() {
    SAMPLE="$2" js "console.log(s.render('$1', { cpuHistory: [10, 20], gpuHistory: [], ...JSON.parse(process.env.SAMPLE) }))"
}
out="$(render cpu '{"cpu": 92}')"
assert_contains "$out" ">92%</text>"
assert_contains "$out" "#f87171"
assert_contains "$out" "<polyline"
assert_contains "$(render memory '{"memory": {"used": 8589934592, "total": 17179869184}, "pressure": 2}')" ">50%</text>"
assert_contains "$(render memory '{"memory": {"used": 1, "total": 2}, "pressure": 2}')" "#facc15"
assert_contains "$(render swap '{"swap": {"used": 571211776, "total": 2147483648}}')" ">545 MB</text>"
assert_contains "$(render disk '{"disk": {"free": 50e9, "total": 1000e9}}')" "#f87171"
assert_contains "$(render top '{"top": {"name": "<a & b> process", "cpu": 5}}')" ">&lt;a &amp; b&gt; pr…</text>"
assert_contains "$(render network '{"network": {"rx": 1200000, "tx": 40000}}')" "↓ 1.2 MB/s"
out="$(render overview '{"cpu": 23, "memory": {"used": 1, "total": 4}, "pressure": 1}')"
assert_contains "$out" ">23%</text>"
assert_contains "$out" ">25%</text>"
for kind in overview cpu memory swap top gpu temperature power disk network; do
    assert_contains "$(render "$kind" '{}')" ">—</text>"
done
assert_contains "$(render gpu '{"macmonMissing": true}')" "needs macmon"
assert_contains "$(render power '{"power": {"system": 7.75, "cpu": 0.42, "gpu": 0.03}}')" ">7.8 W</text>"
# A field macmon no longer gives, as after an update renames it, shows a dash
assert_contains "$(render power '{"power": {"system": 7.75, "gpu": 0.03}}')" ">CPU — · GPU 0.0</text>"
assert_contains "$(js 'console.log(s.placeholder("top"))')" ">TOP CPU</text>"
assert_contains "$(render temperature '{"temperature": {"cpu": 95, "gpu": 44}}')" "#f87171"

# Run JavaScript inside an async function with stats.js as `s`, a fake spawn as `spawnProcess`,
# whose processes are in `children`, and `logs`, which `log` adds to. An unhandled error event
# would end node with a non-zero status.
sampler_js() {
    node -e "(async () => {
const s = require(process.argv[1]);
const { EventEmitter } = require('node:events');
const children = [];
const spawnProcess = () => {
  const c = new EventEmitter();
  c.stdout = new EventEmitter();
  c.killed = false;
  c.kill = () => (c.killed = true);
  children.push(c);
  return c;
};
const logs = [];
const log = (m) => logs.push(m);
$1
})().catch((e) => { console.error(e); process.exit(1); });" "$STATS" "${@:2}"
}

# A macmon that can't start, here a real spawn of a file that isn't executable, emits an error
# event after spawn returns. The sampler logs it rather than crashing the plugin.
touch "$SANDBOX/macmon-not-executable"
out="$(sampler_js 'const sampler = s.createSampler({ log, macmonPath: process.argv[2] });
await sampler.sample(["gpu"]);
await new Promise((r) => setTimeout(r, 300));
console.log(logs.join("\n"));' "$SANDBOX/macmon-not-executable")" || fail "a macmon that can't start ended node: $out"
assert_contains "$out" "couldn't run macmon:"

# A stopped macmon that exits, or prints, after its replacement started changes nothing: the
# replacement keeps running, a third doesn't start, and stopping kills the replacement
assert_eq '{"spawned":2,"killed":[true,true],"gpu":null}' "$(sampler_js 'const sampler = s.createSampler({ log, macmonPath: process.argv[1], spawnProcess });
await sampler.sample(["gpu"]);
sampler.stop();
await sampler.sample(["gpu"]);
children[0].stdout.emit("data", JSON.stringify({ gpu_active_ratio: 0.5 }) + "\n");
children[0].emit("exit", 1, null);
const gpu = (await sampler.sample(["gpu"])).gpu ?? null;
sampler.stop();
console.log(JSON.stringify({ spawned: children.length, killed: children.map((c) => c.killed), gpu }));')" \
    "a stopped macmon's late exit"

# A macmon that keeps exiting, with a status, by a signal, or even with 0, is restarted at once
# twice, then only after a wait, and each exit is logged
crashing_macmon() {
    local code="$1" signal="$2" shown="$3"
    out="$(sampler_js "const sampler = s.createSampler({ log, macmonPath: process.argv[1], spawnProcess });
for (let i = 0; i < 6; i++) {
  await sampler.sample(['gpu']);
  children.at(-1).emit('exit', $code, $signal);
}
console.log(children.length);
console.log(logs.join('\\n'));")"
    assert_eq 3 "$(printf '%s\n' "$out" | head -n 1)" "macmon starts while it keeps exiting ($shown)"
    assert_contains "$out" "macmon exited ($shown)
macmon exited ($shown)
macmon exited ($shown); trying again in 4 s"
}
crashing_macmon 1 null 1
crashing_macmon null "'SIGSEGV'" SIGSEGV
crashing_macmon 0 null 0

# A macmon that prints a sample, then exits, still backs off: a sample doesn't end the row of
# failures. A run that lasted a minute does, so one that exits now and then never waits.
out="$(sampler_js 'const sampler = s.createSampler({ log, macmonPath: process.argv[1], spawnProcess });
for (let i = 0; i < 6; i++) {
  await sampler.sample(["gpu"]);
  children.at(-1).stdout.emit("data", JSON.stringify({ gpu_active_ratio: 0.5 }) + "\n");
  children.at(-1).emit("exit", 1, null);
}
console.log(children.length);
console.log(logs.join("\n"));')"
assert_eq 3 "$(printf '%s\n' "$out" | head -n 1)" "macmon starts while it keeps exiting after a sample"
assert_contains "$out" "macmon exited (1); trying again in 4 s"
out="$(sampler_js 'let t = 0;
const sampler = s.createSampler({ log, macmonPath: process.argv[1], spawnProcess, clock: () => t });
for (let i = 0; i < 6; i++) {
  await sampler.sample(["gpu"]);
  t += 120000;
  children.at(-1).emit("exit", 1, null);
}
console.log(children.length);
console.log(logs.join("\n"));')"
assert_eq 6 "$(printf '%s\n' "$out" | head -n 1)" "macmon starts when each run lasts two minutes"
assert_not_contains "$out" "trying again"

# A macmon spawn throws for, such as ENOEXEC from a file that isn't a program, is a failed start
# like any other: logged, backed off from, and the other stats still update
out="$(sampler_js 'let spawns = 0;
const throwingSpawn = () => {
  spawns++;
  throw Object.assign(new Error("spawn ENOEXEC"), { code: "ENOEXEC" });
};
const sampler = s.createSampler({ log, macmonPath: process.argv[1], spawnProcess: throwingSpawn });
await new Promise((r) => setTimeout(r, 100));
const cpu = (await sampler.sample(["cpu", "gpu"])).cpu != null;
for (let i = 0; i < 5; i++) await sampler.sample(["cpu", "gpu"]);
console.log(spawns, cpu);
console.log(logs.join("\n"));')" || fail "a spawn that throws ended node: $out"
assert_eq "3 true" "$(printf '%s\n' "$out" | head -n 1)" "macmon starts, and CPU samples, while spawn throws"
assert_contains "$out" "couldn't run macmon: spawn ENOEXEC; trying again in 4 s"

# macmon installed while the keys show: they stop saying "needs macmon" without a plugin restart,
# and the missing binary is logged once
out="$(sampler_js 'const fs = require("node:fs");
const sampler = s.createSampler({ log, macmonPath: process.argv[2], spawnProcess });
const before = (await sampler.sample(["gpu"])).macmonMissing;
await sampler.sample(["gpu"]);
fs.writeFileSync(process.argv[2], "");
const after = (await sampler.sample(["gpu"])).macmonMissing;
console.log(JSON.stringify({ before, after, spawned: children.length, logged: logs.length }));' "$SANDBOX/macmon-later")"
assert_eq '{"before":true,"after":false,"spawned":1,"logged":1}' "$out" "macmon installed later"

# A reset, when the keys reappear, clears the sparklines' history
assert_eq "1 0" "$(sampler_js 'const sampler = s.createSampler({ log });
await new Promise((r) => setTimeout(r, 100));
const sample = await sampler.sample(["cpu"]);
const before = sample.cpuHistory.length;
sampler.reset();
console.log(before, sample.cpuHistory.length);')" "the CPU history after a reset"

# The network rate is over the clock's time between samples. A kind no key needs, as when its key
# is hidden while others show, starts afresh when it's needed again: no rate over the gap, and an
# empty sparkline.
assert_eq '[{"rx":500,"tx":50},null,{"rx":1000,"tx":100},0,null]' "$(sampler_js 'let t = 0;
let bytes = 0;
const runCommand = async () => {
  bytes += 1000;
  return `en0 1500 <Link#11> 36:53:3e:4a:e9:c0 1 0 ${bytes} 1 0 ${bytes / 10} 0`;
};
const sampler = s.createSampler({ log, runCommand, clock: () => t });
const rates = [];
await sampler.sample(["network"]);
t += 2000;
rates.push((await sampler.sample(["network"])).network);
await sampler.sample(["disk"]);
t += 60000;
rates.push((await sampler.sample(["network"])).network ?? null);
t += 1000;
rates.push((await sampler.sample(["network"])).network);
await new Promise((r) => setTimeout(r, 100));
const cpu = await sampler.sample(["cpu"]);
await sampler.sample(["disk"]);
rates.push(cpu.cpuHistory.length);
rates.push((await sampler.sample(["cpu"])).cpu ?? null);
console.log(JSON.stringify(rates));')" "rates after a kind is hidden"
# A copy of the plugin whose bin/open-in logs each target and prints "done <target>" as it exits.
# chrome-tab waits until $SANDBOX/release exists, for up to 10 s.
PLUGIN="$SANDBOX/plugin"
mkdir -p "$PLUGIN/bin"
cp "$REPO_DIR"/stream-deck/com.gpahal.dotfiles.sdPlugin/{plugin,stats}.js "$PLUGIN/"
cat > "$PLUGIN/bin/open-in" << EOF
echo "\$1" >> "$SANDBOX/open-in.log"
if [ "\$1" == chrome-tab ]; then
    for _ in \$(seq 200); do [ ! -e "$SANDBOX/release" ] || break; sleep 0.05; done
fi
echo "done \$1"
EOF
# Press New Tab twice and Files twice, let New Tab's open-in exit, then press New Tab again
out="$(node -e 'const sent = [];
let socket;
globalThis.WebSocket = class {
  constructor() { socket = this; }
  send(message) { sent.push(JSON.parse(message)); }
};
process.argv.push("-port", "1", "-pluginUUID", "uuid", "-registerEvent", "register");
require(process.argv[1]);
const press = (key) =>
  socket.onmessage({ data: JSON.stringify({ event: "keyDown", action: `com.gpahal.dotfiles.${key}`, context: key }) });
const done = (key) => sent.filter((m) => m.payload && m.payload.message === `done ${key}`).length;
// Wait up to 10 s for a condition, then fail naming it, rather than leave the test to the watchdog
const until = async (what, test) => {
  const deadline = Date.now() + 10000;
  while (!test()) {
    if (Date.now() > deadline) {
      console.log(`timed out waiting for ${what}; sent: ${JSON.stringify(sent)}`);
      process.exit(1);
    }
    await new Promise((r) => setTimeout(r, 20));
  }
};
(async () => {
  press("chrome-tab"); press("chrome-tab"); press("files"); press("files");
  await until("both Files presses", () => done("files") === 2);
  require("node:fs").writeFileSync(process.argv[2], "");
  await until("the first New Tab", () => done("chrome-tab") >= 1);
  press("chrome-tab");
  await until("the second New Tab", () => done("chrome-tab") >= 2);
  process.exit(0);
})();' "$PLUGIN/plugin.js" "$SANDBOX/release" 2>&1)" || fail "the plugin's key presses failed: $out"
assert_eq "chrome-tab chrome-tab files files" "$(sort "$SANDBOX/open-in.log" | tr '\n' ' ' | sed 's/ $//')" \
    "the open-in runs for New Tab pressed twice, Files twice, then New Tab again"

# A key whose render throws shows its placeholder, and the error is logged once, while the other
# keys still update. A stats.js whose Disk render throws stands in for the real one.
cat > "$PLUGIN/stats.js" << EOF
const real = require("$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/stats.js");
module.exports = { ...real, render: (kind, s) => { if (kind === "disk") throw new Error("broken"); return real.render(kind, s); } };
EOF
out="$(node -e 'const sent = [];
let socket;
globalThis.WebSocket = class {
  constructor() { socket = this; }
  send(message) { sent.push(JSON.parse(message)); }
};
process.argv.push("-port", "1", "-pluginUUID", "uuid", "-registerEvent", "register");
require(process.argv[1]);
const appear = (key) =>
  socket.onmessage({ data: JSON.stringify({ event: "willAppear", action: `com.gpahal.dotfiles.${key}`, context: key }) });
const images = (key) => sent.filter((m) => m.event === "setImage" && m.context === key);
appear("swap"); appear("disk");
(async () => {
  // The first update comes after 0.5 s and the next 2 s later, so a second error would show
  await new Promise((r) => setTimeout(r, 3000));
  const disk = decodeURIComponent(images("disk")[0].payload.image);
  console.log(images("swap").length > 0, disk.includes(">DISK</text>") && disk.includes(">—</text>"));
  console.log(sent.filter((m) => m.payload?.message?.startsWith("ERROR")).map((m) => m.payload.message).join("\n"));
  process.exit(0);
})();' "$PLUGIN/plugin.js" 2>&1)" || fail "the plugin with a broken key failed: $out"
assert_eq "true true
ERROR couldn't draw the disk key: broken" "$out" "a key whose render throws"

# Overview opens the System page on the 15-key Stream Deck (device type 0), and shows a warning on
# any other, which has no page to open
out="$(node -e 'const sent = [];
let socket;
globalThis.WebSocket = class {
  constructor() { socket = this; }
  send(message) { sent.push(JSON.parse(message)); }
};
process.argv.push("-port", "1", "-pluginUUID", "uuid", "-registerEvent", "register");
require(process.argv[1]);
const message = (m) => socket.onmessage({ data: JSON.stringify(m) });
message({ event: "deviceDidConnect", device: "classic", deviceInfo: { type: 0 } });
message({ event: "deviceDidConnect", device: "xl", deviceInfo: { type: 2 } });
for (const device of ["classic", "xl"])
  message({ event: "keyDown", action: "com.gpahal.dotfiles.overview", context: `key-${device}`, device });
for (const m of sent) console.log(m.event, m.device ?? m.context ?? m.payload.message);
process.exit(0);' "$PLUGIN/plugin.js" 2>&1)" || fail "the plugin's Overview presses failed: $out"
assert_eq "switchToProfile classic
logMessage Overview's System page is laid out for the 15-key Stream Deck, not device type 2
showAlert key-xl" "$out" "Overview on the 15-key Stream Deck and on another"
test_done
