#!/bin/bash

# stats.js's netstat and /proc parsers and its macOS and Linux samplers, and keys.js's update loop.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
const deadline = Date.now() + 10000;
while (!logs.length && Date.now() < deadline) await new Promise((r) => setTimeout(r, 10));
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
out="$(sampler_js 'const sampler = s.createSampler({ platform: "darwin", log, macmonPath: process.argv[1], spawnProcess });
for (let i = 0; i < 6; i++) {
  await sampler.sample(["gpu"]);
  children.at(-1).emit("exit", 0, null);
}
console.log(children.length);
console.log(logs.join("\n"));')"
assert_eq "3
macmon exited (0)
macmon exited (0)
macmon exited (0); trying again in 4 s" "$out" "macmon starts while it keeps exiting"

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
mkdir -p "$LINUX/proc/pressure" "$LINUX/proc/net" "$LINUX/sys/class/net/enp6s0/device" \
    "$LINUX/sys/class/drm/card1/device" "$LINUX/sys/class/hwmon/hwmon1" "$LINUX/sys/class/hwmon/hwmon5"
printf '%s\n' "MemTotal: 65536 kB" "MemAvailable: 49152 kB" "SwapTotal: 8192 kB" "SwapFree: 8192 kB" > "$LINUX/proc/meminfo"
printf '%s\n' "some avg10=12.00 avg60=1.00 avg300=0.00 total=1" "full avg10=0.00 avg60=0.00 avg300=0.00 total=1" \
    > "$LINUX/proc/pressure/memory"
echo 37 > "$LINUX/sys/class/drm/card1/device/gpu_busy_percent"
echo k10temp > "$LINUX/sys/class/hwmon/hwmon1/name"
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
# A driver that reloads can move its sensors; a failed read finds them again
out="$(linux_sampler "const first = (await sampler.sample(['temperature'])).temperature;
fs.renameSync(root + '/sys/class/hwmon/hwmon1', root + '/sys/class/hwmon/hwmon2');
const second = (await sampler.sample(['temperature'])).temperature;
console.log(JSON.stringify([first, second]));")"
assert_eq '[{"cpu":55.5,"gpu":41},{"cpu":55.5,"gpu":41}]' "$out" "a moved sensor"

# The overview key names the OS it runs on
for platform in darwin:MAC linux:UBUNTU; do
    out="$(js "Object.defineProperty(process, 'platform', { value: '${platform%%:*}' });
delete require.cache[process.argv[1]];
console.log(require(process.argv[1]).placeholder('overview'))")"
    assert_contains "$out" ">${platform#*:}</text>" "the overview label on ${platform%%:*}"
done

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

test_done
