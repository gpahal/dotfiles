#!/bin/bash
set -euo pipefail

# The Stream Deck plugin's stats.js reads vm_stat, vm.swapusage, ps, and netstat output as
# Activity Monitor counts them, and draws each stat key as an SVG, with a placeholder when a stat
# is missing. Fixed command output stands in for the real machine's.

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

# Only en interfaces' link rows count, including one without an address
netstat='Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
lo0        16384 <Link#1>                      100     0       5000      100     0       5000     0
en0        1500  <Link#11>   36:53:3e:4a:e9:c0     10     0       1000       20     0        200     0
en0        1500  192.168.1     192.168.1.5          10     -       1000       20     -        200     -
en3        1500  <Link#5>                            1     0         30        2     0          4     0
utun4      1380  <Link#20>                          10     0        900       10     0        100     0'
assert_eq '{"rx":1030,"tx":204}' \
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
assert_contains "$(render temperature '{"temperature": {"cpu": 95, "gpu": 44}}')" "#f87171"
test_done
