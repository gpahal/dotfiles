#!/bin/bash
set -euo pipefail

# stats.js's netstat and /proc parsers and its macOS and Linux samplers, keys.js's update loop, and
# the Mac plugin's page switching, with a fake WebSocket.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v node &> /dev/null || skip "node isn't installed"
STATS="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/stats.js"

js() {
    node -e "const s = require(process.argv[1]); $1" "$STATS"
}

# Only en link rows count, down ones (en5*) too, so their counters don't come back as one burst
netstat='Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
lo0        16384 <Link#1>                      100     0       5000      100     0       5000     0
en0        1500  <Link#11>   36:53:3e:4a:e9:c0     10     0       1000       20     0        200     0
en0        1500  192.168.1     192.168.1.5          10     -       1000       20     -        200     -
en3        1500  <Link#5>                            1     0         30        2     0          4     0
en5*       1500  <Link#7>    36:53:3e:4a:e9:c1      1     0       5000        1     0        600     0
utun4      1380  <Link#20>                          10     0        900       10     0        100     0'
assert_eq '{"rx":6030,"tx":804}' \
    "$(NETSTAT="$netstat" js 'console.log(JSON.stringify(s.parseNetstat(process.env.NETSTAT)))')" "network"

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

# A real spawn of a non-executable file emits an error event after spawn returns; unhandled, it
# would end node with a non-zero status
touch "$SANDBOX/macmon-not-executable"
out="$(sampler_js 'const sampler = s.createSampler({ platform: "darwin", log, macmonPath: process.argv[2] });
await sampler.sample(["gpu"]);
await new Promise((r) => setTimeout(r, 300));
console.log(logs.join("\n"));' "$SANDBOX/macmon-not-executable")" || fail "a macmon that can't start ended node: $out"
assert_contains "$out" "couldn't run macmon:"

# A stopped macmon's late exit or output changes nothing
assert_eq '{"spawned":2,"killed":[true,true],"gpu":null}' "$(sampler_js 'const sampler = s.createSampler({ platform: "darwin", log, macmonPath: process.argv[1], spawnProcess });
await sampler.sample(["gpu"]);
sampler.stop();
await sampler.sample(["gpu"]);
children[0].stdout.emit("data", JSON.stringify({ gpu_active_ratio: 0.5 }) + "\n");
children[0].emit("exit", 1, null);
const gpu = (await sampler.sample(["gpu"])).gpu ?? null;
sampler.stop();
console.log(JSON.stringify({ spawned: children.length, killed: children.map((c) => c.killed), gpu }));')" \
    "a stopped macmon's late exit"

# A macmon that keeps exiting, even with 0, is restarted twice, then after a wait
crashing_macmon() {
    local code="$1" signal="$2" shown="$3"
    out="$(sampler_js "const sampler = s.createSampler({ platform: 'darwin', log, macmonPath: process.argv[1], spawnProcess });
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
crashing_macmon 0 null 0

# A sample doesn't reset the backoff; a run that lasted a minute does
out="$(sampler_js 'const sampler = s.createSampler({ platform: "darwin", log, macmonPath: process.argv[1], spawnProcess });
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
const sampler = s.createSampler({ platform: "darwin", log, macmonPath: process.argv[1], spawnProcess, clock: () => t });
for (let i = 0; i < 6; i++) {
  await sampler.sample(["gpu"]);
  t += 120000;
  children.at(-1).emit("exit", 1, null);
}
console.log(children.length);
console.log(logs.join("\n"));')"
assert_eq 6 "$(printf '%s\n' "$out" | head -n 1)" "macmon starts when each run lasts two minutes"
assert_not_contains "$out" "trying again"

# A spawn that throws (ENOEXEC) is a failed start like any other
out="$(sampler_js 'let spawns = 0;
const throwingSpawn = () => {
  spawns++;
  throw Object.assign(new Error("spawn ENOEXEC"), { code: "ENOEXEC" });
};
const sampler = s.createSampler({ platform: "darwin", log, macmonPath: process.argv[1], spawnProcess: throwingSpawn });
await new Promise((r) => setTimeout(r, 100));
const cpu = (await sampler.sample(["cpu", "gpu"])).cpu != null;
for (let i = 0; i < 5; i++) await sampler.sample(["cpu", "gpu"]);
console.log(spawns, cpu);
console.log(logs.join("\n"));')" || fail "a spawn that throws ended node: $out"
assert_eq "3 true" "$(printf '%s\n' "$out" | head -n 1)" "macmon starts, and CPU samples, while spawn throws"
assert_contains "$out" "couldn't run macmon: spawn ENOEXEC; trying again in 4 s"

# macmon installed later is picked up without a plugin restart
out="$(sampler_js 'const fs = require("node:fs");
const sampler = s.createSampler({ platform: "darwin", log, macmonPath: process.argv[2], spawnProcess });
const before = (await sampler.sample(["gpu"])).macmonMissing;
await sampler.sample(["gpu"]);
fs.writeFileSync(process.argv[2], "");
const after = (await sampler.sample(["gpu"])).macmonMissing;
console.log(JSON.stringify({ before, after, spawned: children.length, logged: logs.length }));' "$SANDBOX/macmon-later")"
assert_eq '{"before":true,"after":false,"spawned":1,"logged":1}' "$out" "macmon installed later"

# A kind no key needs starts afresh when needed again: no rate over the gap, empty sparkline
assert_eq '[{"rx":500,"tx":50},null,{"rx":1000,"tx":100},0,null]' "$(sampler_js 'let t = 0;
let bytes = 0;
const runCommand = async () => {
  bytes += 1000;
  return `en0 1500 <Link#11> 36:53:3e:4a:e9:c0 1 0 ${bytes} 1 0 ${bytes / 10} 0`;
};
const sampler = s.createSampler({ platform: "darwin", log, runCommand, clock: () => t });
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

# Linux: a process name with ")" in it, then the sampler against fixture /proc and /sys trees
assert_eq '{"name":"Web Content (x) y","ticks":350}' \
    "$(js 'console.log(JSON.stringify(s.parseProcStat("42 (Web Content (x) y) S 1 42 42 0 -1 4194560 100 0 0 0 300 50 0 0 20 0 1")))')" \
    "a process name with spaces and parentheses"
assert_eq "null" "$(js 'console.log(s.parseProcStat("garbage"))')" "an unreadable /proc/<pid>/stat"

LINUX="$SANDBOX/linux"
proc_stat() {
    mkdir -p "$LINUX/proc/$1"
    echo "$1 ($2) S 1 1 1 0 -1 0 0 0 0 0 $3 0 0 0 20 0 1" > "$LINUX/proc/$1/stat"
}
mkdir -p "$LINUX/proc/pressure" "$LINUX/proc/net" "$LINUX/sys/class/net/enp6s0/device" "$LINUX/sys/class/net/lo" \
    "$LINUX/sys/class/drm/card1/device" "$LINUX/sys/class/drm/card1-HDMI-A-1" \
    "$LINUX/sys/class/hwmon/hwmon0" "$LINUX/sys/class/hwmon/hwmon1" "$LINUX/sys/class/hwmon/hwmon5"
printf '%s\n' "MemTotal: 65536 kB" "MemAvailable: 49152 kB" "SwapTotal: 8192 kB" "SwapFree: 8192 kB" > "$LINUX/proc/meminfo"
printf '%s\n' "some avg10=12.00 avg60=1.00 avg300=0.00 total=1" "full avg10=0.00 avg60=0.00 avg300=0.00 total=1" \
    > "$LINUX/proc/pressure/memory"
echo 37 > "$LINUX/sys/class/drm/card1/device/gpu_busy_percent"
echo nvme > "$LINUX/sys/class/hwmon/hwmon0/name"
echo 30000 > "$LINUX/sys/class/hwmon/hwmon0/temp1_input"
echo k10temp > "$LINUX/sys/class/hwmon/hwmon1/name"
echo Tccd1 > "$LINUX/sys/class/hwmon/hwmon1/temp3_label"
echo 61000 > "$LINUX/sys/class/hwmon/hwmon1/temp3_input"
echo Tctl > "$LINUX/sys/class/hwmon/hwmon1/temp1_label"
echo 55500 > "$LINUX/sys/class/hwmon/hwmon1/temp1_input"
echo amdgpu > "$LINUX/sys/class/hwmon/hwmon5/name"
echo edge > "$LINUX/sys/class/hwmon/hwmon5/temp1_label"
echo 41000 > "$LINUX/sys/class/hwmon/hwmon5/temp1_input"
echo 9000000 > "$LINUX/sys/class/hwmon/hwmon5/power1_input"
echo "45.25 30.5" > "$LINUX/power"
proc_stat 1 systemd 100
proc_stat 200 "Web Content" 1000
proc_stat 300 node 50

linux_sampler() {
    sampler_js "const fs = require('node:fs');
const root = process.argv[2];
let t = Date.now();
const sampler = s.createSampler({ platform: 'linux', log, procRoot: root + '/proc', sysRoot: root + '/sys',
  powerFile: root + '/power', clock: () => t });
$1" "$LINUX"
}

# Rates need two samples: top and network come on the second, 2 s later
out="$(linux_sampler "const kinds = ['memory', 'swap', 'top', 'gpu', 'temperature', 'power', 'network'];
fs.writeFileSync(root + '/proc/net/dev', 'h\nh\nenp6s0: 1000 0 0 0 0 0 0 0 100 0 0 0 0 0 0 0\n    lo: 9 0 0 0 0 0 0 0 9 0 0 0 0 0 0 0\n');
const first = await sampler.sample(kinds);
console.log(JSON.stringify([first.top ?? null, first.network ?? null]));
t += 2000;
fs.writeFileSync(root + '/proc/200/stat', '200 (Web Content) S 1 1 1 0 -1 0 0 0 0 0 1100 100 0 0 20 0 1');
fs.writeFileSync(root + '/proc/300/stat', '300 (node) S 1 1 1 0 -1 0 0 0 0 0 150 0 0 0 20 0 1');
fs.writeFileSync(root + '/proc/net/dev', 'h\nh\nenp6s0: 5000 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0\n    lo: 99999 0 0 0 0 0 0 0 99999 0 0 0 0 0 0 0\n');
const x = await sampler.sample(kinds);
for (const k of ['memory', 'pressure', 'swap', 'top', 'gpu', 'temperature', 'power', 'network']) console.log(k, JSON.stringify(x[k]));")"
assert_eq '[null,null]
memory {"used":16777216,"total":67108864}
pressure 2
swap {"used":0,"total":8388608}
top {"cpu":100,"name":"Web Content"}
gpu {"usage":37}
temperature {"cpu":55.5,"gpu":41}
power {"package":45.25,"cores":30.5,"gpu":9}
network {"rx":2000,"tx":200}' "$out" "the Linux sampler"
# k10temp without Tctl: its first core complex
rm "$LINUX/sys/class/hwmon/hwmon1/temp1_label"
out="$(linux_sampler "console.log(JSON.stringify((await sampler.sample(['temperature'])).temperature));")"
assert_eq '{"cpu":61,"gpu":41}' "$out" "the CPU temperature from Tccd1"

# A stale or missing power file and missing sensors leave dashes with Linux hints, not macmon's
out="$(linux_sampler "fs.utimesSync(root + '/power', new Date(t / 1000 - 60), new Date(t / 1000 - 60));
fs.rmSync(root + '/sys/class/hwmon', { recursive: true });
fs.rmSync(root + '/sys/class/drm', { recursive: true });
const x = await sampler.sample(['gpu', 'temperature', 'power']);
console.log(JSON.stringify([x.gpu, x.temperature, x.power]));
for (const k of ['gpu', 'temperature', 'power']) console.log(s.render(k, x).match(/>([^<>]*)<\/text><\/svg>/)[1]);")"
assert_eq '[null,null,null]
no GPU data
no sensors
needs helper' "$out" "Linux keys with no data"

# keys.js: a key whose render throws shows its placeholder and logs once, and the others update
out="$(node -e 'const keys = require(process.argv[1]);
const logs = [];
const drawn = [];
const sampler = { reset() {}, stop() {}, async sample() { return {}; } };
const stats = { placeholder: (kind) => `placeholder:${kind}`,
  render: (kind) => { if (kind === "disk") throw new Error("broken"); return kind; } };
const k = keys.createStatKeys({ stats, sampler, log: (m) => logs.push(m), draw: (id, svg) => drawn.push(`${id}=${svg}`),
  intervalMs: 5, firstUpdateMs: 1 });
k.keys.set("a", "swap");
k.keys.set("b", "disk");
k.start();
(async () => {
  const deadline = Date.now() + 5000;
  while (drawn.length < 6 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 5));
  k.stop();
  console.log(drawn.slice(0, 6).join(" "));
  console.log(logs.join("\n"));
  process.exit(0);
})();' "$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin/keys.js" 2>&1)" || fail "keys.js with a broken key failed: $out"
assert_eq "a=swap b=placeholder:disk a=swap b=placeholder:disk a=swap b=placeholder:disk
ERROR couldn't draw the disk key: broken" "$out" "a key whose render throws"

PLUGIN="$SANDBOX/plugin"
mkdir -p "$PLUGIN"
cp "$REPO_DIR"/stream-deck/com.gpahal.dotfiles.sdPlugin/{plugin,keys,stats}.js \
    "$REPO_DIR"/stream-deck/com.gpahal.dotfiles.sdPlugin/layout.json "$PLUGIN/"

# Runs $1 in the plugin, with Stream Deck's WebSocket faked: message(m) sends it m, sent holds
# what it sent, and until(what, test) waits up to 10 s
plugin_js() {
    node -e 'const sent = [];
let socket;
globalThis.WebSocket = class {
  constructor() { socket = this; }
  send(message) { sent.push(JSON.parse(message)); }
};
process.argv.push("-port", "1", "-pluginUUID", "uuid", "-registerEvent", "register");
require(process.argv[1]);
const message = (m) => socket.onmessage({ data: JSON.stringify(m) });
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
'"$1"'
process.exit(0);
})();' "$PLUGIN/plugin.js" "${@:2}" 2>&1
}

# A 5×3 deck switches to the Main profile when it connects; Overview opens System and Back Main.
# Another size of deck stays where it is, and Overview alerts.
out="$(plugin_js 'message({ event: "deviceDidConnect", device: "mk2", deviceInfo: { type: 7, size: { columns: 5, rows: 3 } } });
message({ event: "deviceDidConnect", device: "xl", deviceInfo: { type: 2, size: { columns: 8, rows: 4 } } });
for (const [key, device] of [["overview", "mk2"], ["back", "mk2"], ["overview", "xl"], ["back", "unknown"]])
  message({ event: "keyDown", action: `com.gpahal.dotfiles.${key}`, context: `${key}-${device}`, device });
for (const m of sent) console.log([m.event, m.device ?? m.context, m.payload?.profile ?? m.payload?.message].filter(Boolean).join(" "));')"
assert_eq "switchToProfile mk2 profiles/Main
switchToProfile mk2 profiles/System
switchToProfile mk2 profiles/Main
logMessage The dotfiles pages are laid out for 5×3 keys, not 8×4
showAlert overview-xl
logMessage The dotfiles pages are laid out for 5×3 keys, not this device's
showAlert back-unknown" "$out" "switching pages"
test_done
