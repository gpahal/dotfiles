// Live system stats for the plugin's stat keys. createSampler reads what the visible keys need,
// and render draws one key as an SVG. CPU, memory, swap, the top process, disk, and network come
// from macOS's own commands, and GPU, temperature, and power from macmon, which reads Apple
// Silicon's sensors without sudo. Stream Deck starts plugins with a minimal PATH, so commands
// are run by full path.
const { execFile, spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");

const MACMON = "/opt/homebrew/bin/macmon";
// Samples kept for the CPU and GPU sparklines
const HISTORY = 30;
// Failed macmon runs in a row before the next start waits, and the longest wait
const MACMON_RETRIES = 3;
const MACMON_MAX_WAIT_MS = 10 * 60 * 1000;
// How long a macmon run must last before its exit starts the count of failures afresh
const MACMON_HEALTHY_MS = 60 * 1000;
const GIB = 1024 ** 3;

// Activity Monitor's Memory Used: app memory (anonymous pages less purgeable ones), wired, and
// what the compressor occupies
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

// netstat -ibn: the byte counts of each en interface's link row. Counted from the right, since a
// row without an address has one column fewer. Other interfaces, such as utun for a VPN, carry
// traffic en already counts. A down interface is named with a *, as en0*. It keeps its counters,
// so leaving it out would count its lifetime total as one sample's traffic when it comes back up.
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

// Which stats each key needs
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

// macmonPath, spawnProcess, and clock stand in for macmon, child_process.spawn, and Date.now in tests
function createSampler({
  log = () => {},
  macmonPath = MACMON,
  spawnProcess = spawn,
  clock = Date.now,
} = {}) {
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

  // A macmon run that failed to start or exited. After MACMON_RETRIES in a row, each start waits
  // twice as long as the one before, so a macmon that keeps crashing isn't restarted, and logged,
  // every 2 seconds. A run that lasted MACMON_HEALTHY_MS ends the row, but one that printed a
  // sample or two before exiting doesn't.
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

  // A failure of child, counted only while it's the current run
  function macmonFailed(child, message) {
    if (macmon === child) recordFailure(message);
  }

  // Runs macmon only while a key needs it; it prints a JSON line every 2 seconds. Each callback
  // changes state only while its process is still the current one: a process stopped and
  // replaced can still exit, or print, after its replacement started.
  function startMacmon() {
    if (macmon || clock() < retryAt) return;
    // Checked on each start, so installing macmon takes effect without restarting the plugin
    const missing = !fs.existsSync(macmonPath);
    if (missing && !macmonMissing) log("macmon isn't installed; GPU, temperature, and power keys show nothing");
    macmonMissing = missing;
    if (missing) return;
    let child;
    startedAt = clock();
    try {
      child = spawnProcess(macmonPath, ["pipe", "-i", "2000"], { stdio: ["ignore", "pipe", "ignore"] });
    } catch (error) {
      // spawn throws some errors, such as ENOEXEC and EPERM, rather than emitting them
      recordFailure(`couldn't run macmon: ${error.message}`);
      return;
    }
    macmon = child;
    // Without a listener, a spawn error, such as from a macmon that isn't executable or that an
    // upgrade removed since the check above, would crash the whole plugin
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
    // macmon runs until stopped, so any exit of the current run, even with 0 or by a signal,
    // is a failure. The exit stopMacmon's kill causes comes later, once macmon no longer names
    // child, so it isn't counted.
    child.on("exit", (code, signal) => macmonFailed(child, `macmon exited (${signal ?? code})`));
  }

  function stopMacmon() {
    macmon?.kill();
    macmon = null;
    macmonLatest = null;
  }

  // Starts the rates and sparklines afresh, so the first sample after the keys reappear covers
  // only the time since, and no line joins across the gap
  function reset() {
    cpuPrev = cpuTimes();
    netPrev = null;
    cpuHistory.length = 0;
    gpuHistory.length = 0;
  }

  async function sample(kinds) {
    const needed = new Set(kinds.flatMap((kind) => NEEDS[kind] ?? []));
    const s = { cpuHistory, gpuHistory };
    if (needed.has("macmon")) startMacmon();
    else stopMacmon();
    const jobs = [];
    if (needed.has("cpu")) {
      const now = cpuTimes();
      const total = now.total - cpuPrev.total;
      s.cpu = total > 0 ? (1 - (now.idle - cpuPrev.idle) / total) * 100 : null;
      cpuPrev = now;
      if (s.cpu != null) push(cpuHistory, s.cpu);
    }
    if (needed.has("memory")) {
      jobs.push(
        run("/usr/bin/vm_stat", []).then((out) => {
          if (out) s.memory = { used: parseVmStat(out), total: os.totalmem() };
        }),
      );
    }
    // Memory pressure and swap from one sysctl, which prints each value on its own line
    const keys = [];
    if (needed.has("memory")) keys.push("kern.memorystatus_vm_pressure_level");
    if (needed.has("swap")) keys.push("vm.swapusage");
    if (keys.length > 0) {
      jobs.push(
        run("/usr/sbin/sysctl", ["-n", ...keys]).then((out) => {
          if (!out) return;
          const values = out.split("\n");
          if (needed.has("memory")) s.pressure = Number(values.shift());
          if (needed.has("swap")) s.swap = parseSwap(values.shift() ?? "");
        }),
      );
    }
    if (needed.has("top")) {
      jobs.push(
        run("/bin/ps", ["-Aceo", "pcpu=,comm=", "-r"]).then((out) => {
          if (out) s.top = parseTop(out);
        }),
      );
    }
    if (needed.has("disk")) {
      try {
        const { bavail, blocks, bsize } = fs.statfsSync("/");
        s.disk = { free: bavail * bsize, total: blocks * bsize };
      } catch (error) {
        log(`couldn't read the disk's free space: ${error.message}`);
      }
    }
    if (needed.has("network")) {
      jobs.push(
        // -n skips looking up each address's name, which takes seconds
        run("/usr/sbin/netstat", ["-ibn"]).then((out) => {
          if (!out) return;
          const now = { ...parseNetstat(out), at: Date.now() };
          if (netPrev && now.at > netPrev.at) {
            const seconds = (now.at - netPrev.at) / 1000;
            s.network = {
              rx: Math.max(0, now.rx - netPrev.rx) / seconds,
              tx: Math.max(0, now.tx - netPrev.tx) / seconds,
            };
          }
          netPrev = now;
        }),
      );
    }
    await Promise.all(jobs);
    if (needed.has("macmon")) {
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

// Drawing. Keys are 144 pixels square, which Stream Deck scales to the device.
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

// Memory and swap in binary units, as Activity Monitor shows them, and disk and network in
// decimal ones, as Finder does
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

// The newest sample at the right edge
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

// A key's background and label, then the rest of its drawing
function frame(label, ...parts) {
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">`,
    `<rect width="144" height="144" fill="${COLORS.background}"/>`,
    text(72, 30, 19, COLORS.label, label),
    ...parts,
    `</svg>`,
  ].join("");
}

// A key with a label, a large value, and an optional line under it, then any extra drawing
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
      // ps counts one core as 100%, as Activity Monitor does
      text(72, 116, 34, level(s.top.cpu, 50, 100), formatPercent(s.top.cpu), { weight: 700 }),
    );
  },
  gpu(s) {
    if (!s.gpu) return empty("GPU", s.macmonMissing ? "needs macmon" : "");
    const color = level(s.gpu.usage, 60, 85);
    return card("GPU", formatPercent(s.gpu.usage), color, "", sparkline(s.gpuHistory, color));
  },
  temperature(s) {
    if (!s.temperature?.cpu) return empty("TEMP", s.macmonMissing ? "needs macmon" : "");
    const { cpu, gpu } = s.temperature;
    return card("TEMP", `${Math.round(cpu)}°`, level(cpu, 75, 90), gpu ? `GPU ${Math.round(gpu)}°` : "CPU");
  },
  power(s) {
    if (s.power?.system == null) return empty("POWER", s.macmonMissing ? "needs macmon" : "");
    const { system, cpu, gpu } = s.power;
    return card("POWER", `${system.toFixed(1)} W`, COLORS.text, `CPU ${cpu.toFixed(1)} · GPU ${gpu.toFixed(1)}`);
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

module.exports = {
  createSampler,
  isStat,
  render,
  formatBytes,
  parseNetstat,
  parseSwap,
  parseTop,
  parseVmStat,
};
