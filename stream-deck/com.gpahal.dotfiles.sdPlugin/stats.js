// Commands run by full path, since Stream Deck starts plugins with a minimal PATH; GPU,
// temperature, and power come from macmon. Linux reads /proc and /sys instead, for the Ubuntu
// daemon in stream-deck/linux, with the sensors of an AMD CPU and GPU.
const { execFile, spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");

const MACMON = "/opt/homebrew/bin/macmon";
const HISTORY = 30;
// Failed macmon runs in a row before backoff starts
const MACMON_RETRIES = 3;
const MACMON_MAX_WAIT_MS = 10 * 60 * 1000;
// A run this long resets the failure count
const MACMON_HEALTHY_MS = 60 * 1000;
const GIB = 1024 ** 3;

// Matches Activity Monitor's Memory Used
function parseVmStat(text) {
  const pageSize = Number(/page size of (\d+) bytes/.exec(text)?.[1] ?? 16384);
  const pages = (name) => Number(new RegExp(`^${name}:\\s+(\\d+)`, "m").exec(text)?.[1] ?? 0);
  const app = pages("Anonymous pages") - pages("Pages purgeable");
  return (app + pages("Pages wired down") + pages("Pages occupied by compressor")) * pageSize;
}

// vm.swapusage: total = 2048.00M  used = 544.75M  free = 1503.25M  (encrypted)
function parseSwap(text) {
  const mib = (name) => Number(new RegExp(`${name} = ([\\d.]+)M`).exec(text)?.[1] ?? 0) * 1024 ** 2;
  return { used: mib("used"), total: mib("total") };
}

// en link rows only: utun etc. carry traffic en already counts. Columns counted from the right,
// since a row without an address has one fewer. Down interfaces (en0*) are kept, or their lifetime
// total would count as one sample when they come back up.
function parseNetstat(text) {
  let rx = 0;
  let tx = 0;
  for (const line of text.split("\n")) {
    const cols = line.trim().split(/\s+/);
    if (!/^en\d+\*?$/.test(cols[0]) || !cols[2]?.startsWith("<Link#")) continue;
    rx += Number(cols.at(-5));
    tx += Number(cols.at(-2));
  }
  return { rx, tx };
}

// ps -Aceo pcpu=,comm= -r: the first line is the busiest process
function parseTop(text) {
  const match = /^\s*([\d.]+)\s+(.+)$/m.exec(text);
  return match ? { cpu: Number(match[1]), name: match[2].trim() } : null;
}

// Linux: /proc/meminfo counts kB. Used is what Resources and free(1) show: total less available.
function parseMeminfo(text) {
  const kb = (name) => Number(new RegExp(`^${name}:\\s+(\\d+) kB`, "m").exec(text)?.[1] ?? 0) * 1024;
  return {
    total: kb("MemTotal"),
    available: kb("MemAvailable"),
    swapTotal: kb("SwapTotal"),
    swapFree: kb("SwapFree"),
  };
}

// /proc/pressure/memory's "some avg10": the share of the last 10 s that some task stalled on
// memory. Mapped to macOS's pressure levels, so Memory keeps its colors.
function parsePressure(text) {
  const avg10 = Number(/^some avg10=([\d.]+)/m.exec(text)?.[1]);
  if (Number.isNaN(avg10)) return null;
  return avg10 >= 40 ? 4 : avg10 >= 10 ? 2 : 1;
}

// /proc/net/dev: after two header lines, "name: rx_bytes ... (8 rx columns) tx_bytes ..."
function parseNetDev(text, include = () => true) {
  let rx = 0;
  let tx = 0;
  for (const line of text.split("\n").slice(2)) {
    const match = /^\s*([^:\s]+):\s*(.*)$/.exec(line);
    if (!match || !include(match[1])) continue;
    const cols = match[2].trim().split(/\s+/);
    rx += Number(cols[0]);
    tx += Number(cols[8]);
  }
  return { rx, tx };
}

// /proc/<pid>/stat: the name sits in parentheses and can hold spaces or ")", so fields are counted
// after the last ")". utime and stime are fields 14 and 15.
function parseProcStat(text) {
  const open = text.indexOf("(");
  const close = text.lastIndexOf(")");
  if (open === -1 || close < open) return null;
  const fields = text.slice(close + 2).split(" ");
  const ticks = Number(fields[11]) + Number(fields[12]);
  return Number.isNaN(ticks) ? null : { name: text.slice(open + 1, close), ticks };
}

function cpuTimes() {
  let idle = 0;
  let total = 0;
  for (const { times } of os.cpus()) {
    idle += times.idle;
    total += times.user + times.nice + times.sys + times.idle + times.irq;
  }
  return { idle, total };
}

const run = (file, args) =>
  new Promise((resolve) =>
    execFile(file, args, { timeout: 2000 }, (error, stdout) => resolve(error ? null : stdout)),
  );

const NEEDS = {
  overview: ["cpu", "memory"],
  cpu: ["cpu"],
  memory: ["memory"],
  swap: ["swap"],
  top: ["top"],
  gpu: ["macmon"],
  temperature: ["macmon"],
  power: ["macmon"],
  disk: ["disk"],
  network: ["network"],
};

// Linux reads each from /sys or the power helper, so needs no macmon
const LINUX_NEEDS = { ...NEEDS, gpu: ["gpu"], temperature: ["temperature"], power: ["power"] };

// Written by the stream-deck step's root helper, since RAPL's counters are root-only
const POWER_FILE = "/run/dotfiles-power/watts";
// The helper writes every 2 s; older means it stopped
const POWER_STALE_MS = 10 * 1000;
// Linux's USER_HZ, the unit of /proc/<pid>/stat's times, is 100 on every architecture Ubuntu ships
const CLK_TCK = 100;
// k10temp's control temperature, else its first core complex's
const CPU_LABELS = ["Tctl", "Tccd1"];

// The options are test seams
function createSampler({
  log = () => {},
  macmonPath = MACMON,
  spawnProcess = spawn,
  runCommand = run,
  clock = Date.now,
  platform = process.platform,
  procRoot = "/proc",
  sysRoot = "/sys",
  powerFile = POWER_FILE,
} = {}) {
  const linux = platform === "linux";
  const needs = linux ? LINUX_NEEDS : NEEDS;
  let topPrev = null;
  let cpuPrev = cpuTimes();
  let netPrev = null;
  const cpuHistory = [];
  const gpuHistory = [];
  let macmon = null;
  let macmonLatest = null;
  let macmonMissing = false;
  let startedAt = 0;
  let failures = 0;
  let retryAt = 0;

  // Exponential backoff, so a crashing macmon isn't restarted and logged every 2 seconds
  function recordFailure(message) {
    macmon = null;
    macmonLatest = null;
    if (clock() - startedAt >= MACMON_HEALTHY_MS) failures = 0;
    failures++;
    let wait = "";
    if (failures >= MACMON_RETRIES) {
      const ms = Math.min(2000 * 2 ** (failures - MACMON_RETRIES + 1), MACMON_MAX_WAIT_MS);
      retryAt = clock() + ms;
      wait = `; trying again in ${Math.round(ms / 1000)} s`;
    }
    log(`${message}${wait}`);
  }

  function macmonFailed(child, message) {
    if (macmon === child) recordFailure(message);
  }

  // Callbacks check the child is current: a replaced process can still exit or print
  function startMacmon() {
    if (macmon || clock() < retryAt) return;
    // Checked each start, so installing macmon needs no plugin restart
    const missing = !fs.existsSync(macmonPath);
    if (missing && !macmonMissing) log("macmon isn't installed; GPU, temperature, and power keys show nothing");
    macmonMissing = missing;
    if (missing) return;
    let child;
    startedAt = clock();
    try {
      child = spawnProcess(macmonPath, ["pipe", "-i", "2000"], { stdio: ["ignore", "pipe", "ignore"] });
    } catch (error) {
      // spawn throws some errors, such as ENOEXEC and EPERM
      recordFailure(`couldn't run macmon: ${error.message}`);
      return;
    }
    macmon = child;
    // Without a listener, a spawn error would crash the plugin
    child.on("error", (error) => macmonFailed(child, `couldn't run macmon: ${error.message}`));
    let buffer = "";
    child.stdout?.on("data", (chunk) => {
      if (macmon !== child) return;
      buffer += chunk;
      const lines = buffer.split("\n");
      buffer = lines.pop();
      for (const line of lines) {
        try {
          macmonLatest = JSON.parse(line);
        } catch {
          // A partial line from a macmon that's quitting
        }
      }
    });
    // macmon runs until stopped, so any exit of the current run is a failure
    child.on("exit", (code, signal) => macmonFailed(child, `macmon exited (${signal ?? code})`));
  }

  function stopMacmon() {
    macmon?.kill();
    macmon = null;
    macmonLatest = null;
  }

  // So rates and sparklines don't span the time keys were hidden
  function reset() {
    cpuPrev = cpuTimes();
    netPrev = null;
    topPrev = null;
    cpuHistory.length = 0;
    gpuHistory.length = 0;
  }

  // A missing or unreadable file is null, so its key shows a dash
  const read = (file) => fs.promises.readFile(file, "utf8").catch(() => null);
  const readNumber = async (file) => {
    const text = await read(file);
    const value = text == null ? NaN : Number(text.trim());
    return Number.isNaN(value) ? null : value;
  };

  // Physical interfaces only: docker0 and tailscale0 carry traffic they already count, and lo's
  // never leaves the machine
  const physical = (name) => fs.existsSync(`${sysRoot}/class/net/${name}/device`);

  // Shares of each process's CPU time since the last sample; one core is 100%, as on macOS
  async function linuxTop() {
    const pids = (await fs.promises.readdir(procRoot).catch(() => [])).filter((name) => /^\d+$/.test(name));
    const now = { at: clock(), procs: new Map() };
    await Promise.all(
      pids.map(async (pid) => {
        const text = await read(`${procRoot}/${pid}/stat`);
        const proc = text && parseProcStat(text);
        if (proc) now.procs.set(pid, proc);
      }),
    );
    let top = null;
    if (topPrev && now.at > topPrev.at) {
      const seconds = (now.at - topPrev.at) / 1000;
      for (const [pid, { name, ticks }] of now.procs) {
        const before = topPrev.procs.get(pid);
        if (!before || before.name !== name) continue;
        const cpu = ((ticks - before.ticks) / CLK_TCK / seconds) * 100;
        if (!top || cpu > top.cpu) top = { cpu, name };
      }
    }
    topPrev = now;
    return top;
  }

  async function hwmons() {
    const base = `${sysRoot}/class/hwmon`;
    const dirs = await fs.promises.readdir(base).catch(() => []);
    return Promise.all(dirs.map(async (dir) => ({ dir: `${base}/${dir}`, name: (await read(`${base}/${dir}/name`))?.trim() })));
  }

  // The first of the labels the sensor has; in °C
  async function hwmonTemp(dir, labels) {
    const files = (await fs.promises.readdir(dir).catch(() => [])).filter((f) => /^temp\d+_label$/.test(f));
    const found = new Map(await Promise.all(files.map(async (f) => [(await read(`${dir}/${f}`))?.trim(), f])));
    const file = labels.map((label) => found.get(label)).find(Boolean);
    const value = file ? await readNumber(`${dir}/${file.replace("_label", "_input")}`) : null;
    return value == null ? null : value / 1000;
  }

  async function gpuBusy() {
    const base = `${sysRoot}/class/drm`;
    const cards = (await fs.promises.readdir(base).catch(() => [])).filter((name) => /^card\d+$/.test(name));
    for (const card of cards.sort()) {
      const value = await readNumber(`${base}/${card}/device/gpu_busy_percent`);
      if (value != null) return value;
    }
    return null;
  }

  // "<package W> <cores W>", from the root helper
  async function raplPower() {
    try {
      const { mtimeMs } = await fs.promises.stat(powerFile);
      if (clock() - mtimeMs > POWER_STALE_MS) return null;
    } catch {
      return null;
    }
    const [pkg, cores] = ((await read(powerFile)) ?? "").trim().split(/\s+/).map(Number);
    return Number.isNaN(pkg) ? null : { pkg, cores: Number.isNaN(cores) ? null : cores };
  }

  function linuxJobs(needed, s, setNetwork) {
    const jobs = [];
    if (needed.has("memory") || needed.has("swap")) {
      jobs.push(
        read(`${procRoot}/meminfo`).then((text) => {
          if (!text) return;
          const m = parseMeminfo(text);
          if (needed.has("memory") && m.total) s.memory = { used: m.total - m.available, total: m.total };
          if (needed.has("swap")) s.swap = { used: m.swapTotal - m.swapFree, total: m.swapTotal };
        }),
      );
    }
    if (needed.has("memory")) {
      jobs.push(
        read(`${procRoot}/pressure/memory`).then((text) => {
          if (text) s.pressure = parsePressure(text);
        }),
      );
    }
    if (needed.has("top")) jobs.push(linuxTop().then((top) => (s.top = top)));
    if (needed.has("network")) {
      jobs.push(
        read(`${procRoot}/net/dev`).then((text) => {
          if (text) setNetwork(parseNetDev(text, physical));
        }),
      );
    }
    if (needed.has("gpu")) {
      jobs.push(
        gpuBusy().then((usage) => {
          s.gpu = usage == null ? null : { usage };
          if (s.gpu) push(gpuHistory, usage);
        }),
      );
    }
    if (needed.has("temperature") || needed.has("power")) {
      jobs.push(
        (async () => {
          const sensors = await hwmons();
          const cpuDir = sensors.find((h) => h.name === "k10temp")?.dir;
          const gpuDir = sensors.find((h) => h.name === "amdgpu")?.dir;
          if (needed.has("temperature")) {
            const cpu = cpuDir ? await hwmonTemp(cpuDir, CPU_LABELS) : null;
            const gpu = gpuDir ? await hwmonTemp(gpuDir, ["edge"]) : null;
            s.temperature = cpu == null ? null : { cpu, gpu };
          }
          if (needed.has("power")) {
            // In µW
            const gpuMicro = gpuDir ? await readNumber(`${gpuDir}/power1_input`) : null;
            const rapl = await raplPower();
            s.power = rapl && { package: rapl.pkg, cores: rapl.cores, gpu: gpuMicro == null ? null : gpuMicro / 1e6 };
          }
        })(),
      );
    }
    return jobs;
  }

  function macJobs(needed, s, setNetwork) {
    const jobs = [];
    if (needed.has("memory")) {
      jobs.push(
        runCommand("/usr/bin/vm_stat", []).then((out) => {
          if (out) s.memory = { used: parseVmStat(out), total: os.totalmem() };
        }),
      );
    }
    const keys = [];
    if (needed.has("memory")) keys.push("kern.memorystatus_vm_pressure_level");
    if (needed.has("swap")) keys.push("vm.swapusage");
    if (keys.length > 0) {
      jobs.push(
        runCommand("/usr/sbin/sysctl", ["-n", ...keys]).then((out) => {
          if (!out) return;
          const values = out.split("\n");
          if (needed.has("memory")) s.pressure = Number(values.shift());
          if (needed.has("swap")) s.swap = parseSwap(values.shift() ?? "");
        }),
      );
    }
    if (needed.has("top")) {
      jobs.push(
        runCommand("/bin/ps", ["-Aceo", "pcpu=,comm=", "-r"]).then((out) => {
          if (out) s.top = parseTop(out);
        }),
      );
    }
    if (needed.has("network")) {
      jobs.push(
        // -n: name lookups take seconds
        runCommand("/usr/sbin/netstat", ["-ibn"]).then((out) => {
          if (out) setNetwork(parseNetstat(out));
        }),
      );
    }
    return jobs;
  }

  async function sample(kinds) {
    const needed = new Set(kinds.flatMap((kind) => needs[kind] ?? []));
    const s = { cpuHistory, gpuHistory };
    // Reset unneeded kinds, so a first rate doesn't span the time they were hidden
    if (needed.has("macmon")) {
      startMacmon();
    } else {
      stopMacmon();
      if (!needed.has("gpu")) gpuHistory.length = 0;
    }
    if (!needed.has("cpu")) {
      cpuPrev = null;
      cpuHistory.length = 0;
    }
    if (!needed.has("network")) netPrev = null;
    if (!needed.has("top")) topPrev = null;
    if (needed.has("cpu")) {
      const now = cpuTimes();
      const total = cpuPrev ? now.total - cpuPrev.total : 0;
      s.cpu = total > 0 ? (1 - (now.idle - cpuPrev.idle) / total) * 100 : null;
      cpuPrev = now;
      if (s.cpu != null) push(cpuHistory, s.cpu);
    }
    if (needed.has("disk")) {
      try {
        const { bavail, blocks, bsize } = fs.statfsSync("/");
        s.disk = { free: bavail * bsize, total: blocks * bsize };
      } catch (error) {
        log(`couldn't read the disk's free space: ${error.message}`);
      }
    }
    const setNetwork = (counts) => {
      const now = { ...counts, at: clock() };
      if (netPrev && now.at > netPrev.at) {
        const seconds = (now.at - netPrev.at) / 1000;
        s.network = {
          rx: Math.max(0, now.rx - netPrev.rx) / seconds,
          tx: Math.max(0, now.tx - netPrev.tx) / seconds,
        };
      }
      netPrev = now;
    };
    await Promise.all((linux ? linuxJobs : macJobs)(needed, s, setNetwork));
    if (linux) {
      s.hints = { gpu: "no GPU data", temperature: "no sensors", power: "needs helper" };
    } else if (needed.has("macmon")) {
      s.macmonMissing = macmonMissing;
      if (macmonLatest) {
        const m = macmonLatest;
        s.gpu = m.gpu_active_ratio == null ? null : { usage: m.gpu_active_ratio * 100 };
        if (s.gpu) push(gpuHistory, s.gpu.usage);
        s.temperature = m.temp ? { cpu: m.temp.cpu_temp_avg, gpu: m.temp.gpu_temp_avg } : null;
        s.power = { system: m.sys_power, cpu: m.cpu_power, gpu: m.gpu_power };
      }
    }
    return s;
  }

  return { sample, reset, stop: stopMacmon };
}

function push(history, value) {
  history.push(value);
  if (history.length > HISTORY) history.shift();
}

const COLORS = {
  background: "#18181b",
  label: "#a1a1aa",
  text: "#f4f4f5",
  muted: "#71717a",
  track: "#3f3f46",
  ok: "#4ade80",
  warn: "#facc15",
  bad: "#f87171",
  download: "#60a5fa",
  upload: "#c084fc",
};

const level = (value, warn, bad) => (value >= bad ? COLORS.bad : value >= warn ? COLORS.warn : COLORS.ok);

const escape = (text) =>
  String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// Memory and swap in binary units, as Activity Monitor; disk and network decimal, as Finder
function formatBytes(bytes, base = 1000) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (bytes >= base && i < units.length - 1) {
    bytes /= base;
    i++;
  }
  const digits = i === 0 || bytes >= 100 ? 0 : 1;
  return `${bytes.toFixed(digits)} ${units[i]}`;
}

const formatPercent = (value) => `${Math.round(value)}%`;

function text(x, y, size, fill, content, { anchor = "middle", weight = 600 } = {}) {
  return `<text x="${x}" y="${y}" font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}">${escape(content)}</text>`;
}

function bar(ratio, color) {
  const width = Math.max(0, Math.min(1, ratio)) * 112;
  return `<rect x="16" y="120" width="112" height="8" rx="4" fill="${COLORS.track}"/><rect x="16" y="120" width="${width.toFixed(1)}" height="8" rx="4" fill="${color}"/>`;
}

function sparkline(history, color) {
  if (history.length < 2) return "";
  const points = history
    .map((value, i) => {
      const x = 128 - ((history.length - 1 - i) * 112) / (HISTORY - 1);
      const y = 132 - (Math.max(0, Math.min(100, value)) / 100) * 22;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");
  return `<polyline points="${points}" fill="none" stroke="${color}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>`;
}

// Keys are drawn at 144 px; Stream Deck, or the Ubuntu daemon, scales them to the device
function frame(label, ...parts) {
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">`,
    `<rect width="144" height="144" fill="${COLORS.background}"/>`,
    text(72, 30, 19, COLORS.label, label),
    ...parts,
    `</svg>`,
  ].join("");
}

function card(label, value, valueColor, sub, extra = "") {
  return frame(
    label,
    // Values such as "545 MB" are too wide for the full size
    text(72, 78, String(value).length > 4 ? 34 : 40, valueColor, value, { weight: 700 }),
    sub ? text(72, 106, 17, COLORS.text, sub, { weight: 500 }) : "",
    extra,
  );
}

const empty = (label, sub = "") => card(label, "—", COLORS.muted, sub);

// A dash when macmon lacks the field, as after an update renames it
const watts = (value) => (typeof value === "number" ? value.toFixed(1) : "—");

// Why a GPU, temperature, or power key is empty
const hint = (s, kind) => (s.macmonMissing ? "needs macmon" : (s.hints?.[kind] ?? ""));

const PRESSURE = { 1: COLORS.ok, 2: COLORS.warn, 4: COLORS.bad };

const RENDER = {
  overview(s) {
    const row = (y, name, value, color) =>
      text(12, y, 20, COLORS.label, name, { anchor: "start" }) +
      text(134, y, value.length > 3 ? 28 : 32, color, value, { anchor: "end", weight: 700 });
    const cpu = s.cpu == null ? ["—", COLORS.muted] : [formatPercent(s.cpu), level(s.cpu, 60, 85)];
    const mem = s.memory
      ? [formatPercent((s.memory.used / s.memory.total) * 100), PRESSURE[s.pressure] ?? COLORS.text]
      : ["—", COLORS.muted];
    return frame("SYSTEM", row(78, "CPU", ...cpu), row(120, "MEM", ...mem));
  },
  cpu(s) {
    if (s.cpu == null) return empty("CPU");
    const color = level(s.cpu, 60, 85);
    return card("CPU", formatPercent(s.cpu), color, "", sparkline(s.cpuHistory, color));
  },
  memory(s) {
    if (!s.memory) return empty("MEMORY");
    const { used, total } = s.memory;
    const color = PRESSURE[s.pressure] ?? COLORS.text;
    const sub = `${(used / GIB).toFixed(1)} of ${Math.round(total / GIB)} GB`;
    return card("MEMORY", formatPercent((used / total) * 100), color, sub, bar(used / total, color));
  },
  swap(s) {
    if (!s.swap) return empty("SWAP");
    const { used, total } = s.swap;
    // macOS grows swap as it needs it, so its total says little; color by how much is used
    const color = level(used, 1 * GIB, 4 * GIB);
    return card("SWAP", formatBytes(used, 1024), color, total ? `of ${formatBytes(total, 1024)}` : "");
  },
  top(s) {
    if (!s.top) return empty("TOP CPU");
    const name = s.top.name.length > 11 ? `${s.top.name.slice(0, 10)}…` : s.top.name;
    return frame(
      "TOP CPU",
      text(72, 74, 22, COLORS.text, name, { weight: 700 }),
      // One core is 100%, as in Activity Monitor
      text(72, 116, 34, level(s.top.cpu, 50, 100), formatPercent(s.top.cpu), { weight: 700 }),
    );
  },
  gpu(s) {
    if (!s.gpu) return empty("GPU", hint(s, "gpu"));
    const color = level(s.gpu.usage, 60, 85);
    return card("GPU", formatPercent(s.gpu.usage), color, "", sparkline(s.gpuHistory, color));
  },
  temperature(s) {
    if (!s.temperature?.cpu) return empty("TEMP", hint(s, "temperature"));
    const { cpu, gpu } = s.temperature;
    return card("TEMP", `${Math.round(cpu)}°`, level(cpu, 75, 90), gpu ? `GPU ${Math.round(gpu)}°` : "CPU");
  },
  power(s) {
    // Linux has no whole-machine figure: the CPU package, its cores, and the GPU. The second line
    // rounds to whole watts, since a desktop CPU's tens of watts with decimals overflow the key.
    if (typeof s.power?.package === "number") {
      const { package: pkg, cores, gpu } = s.power;
      const whole = (value) => (typeof value === "number" ? Math.round(value) : "—");
      return card("POWER", `${watts(pkg)} W`, COLORS.text, `Core ${whole(cores)} · GPU ${whole(gpu)}`);
    }
    if (typeof s.power?.system !== "number") return empty("POWER", hint(s, "power"));
    const { system, cpu, gpu } = s.power;
    return card("POWER", `${watts(system)} W`, COLORS.text, `CPU ${watts(cpu)} · GPU ${watts(gpu)}`);
  },
  disk(s) {
    if (!s.disk) return empty("DISK");
    const { free, total } = s.disk;
    const color = free / total < 0.1 ? COLORS.bad : free / total < 0.2 ? COLORS.warn : COLORS.ok;
    return card("DISK", formatBytes(free), color, "free", bar(1 - free / total, color));
  },
  network(s) {
    if (!s.network) return empty("NETWORK");
    const rate = (bytes) => `${formatBytes(bytes)}/s`;
    return frame(
      "NETWORK",
      text(72, 78, 22, COLORS.download, `↓ ${rate(s.network.rx)}`, { weight: 700 }),
      text(72, 116, 22, COLORS.upload, `↑ ${rate(s.network.tx)}`, { weight: 700 }),
    );
  },
};

const isStat = (kind) => Object.hasOwn(RENDER, kind);
const render = (kind, s) => RENDER[kind](s);
// Each key drawn with no data
const placeholder = (kind) => RENDER[kind]({});

module.exports = {
  createSampler,
  isStat,
  placeholder,
  render,
  formatBytes,
  parseMeminfo,
  parseNetDev,
  parseNetstat,
  parsePressure,
  parseProcStat,
  parseSwap,
  parseTop,
  parseVmStat,
};
