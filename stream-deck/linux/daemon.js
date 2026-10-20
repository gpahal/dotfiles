// Drives the Stream Deck on Ubuntu with the Mac plugin's keys. The dotfiles-stream-deck user
// service runs it from the copy the stream-deck step installs, beside stats.js, images/, and
// bin/open-in. layout.json places the keys; it logs to the journal.
const { execFile } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const OPEN_IN_TARGETS = new Set([
  "files",
  "editor",
  "terminal",
  "claude",
  "chrome",
  "chrome-tab",
  "gmail",
  "t3-code",
  "activity-monitor",
]);
// Keys that switch pages, as the Mac plugin's switchToProfile does
const PAGE_KEYS = { overview: "system", back: "main" };
// A second New Tab press while the first runs would open a second tab and paste twice
const ONE_AT_A_TIME = new Set(["chrome-tab"]);
const BLANK = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><rect width="144" height="144" fill="#000"/></svg>`;
// Like Stream Deck's showAlert
const ALERT = [
  `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">`,
  `<rect width="144" height="144" fill="#18181b"/>`,
  `<path d="M72 26 124 116H20Z" fill="#facc15" stroke="#facc15" stroke-width="10" stroke-linejoin="round"/>`,
  `<rect x="66" y="56" width="12" height="34" rx="6" fill="#18181b"/><circle cx="72" cy="102" r="7" fill="#18181b"/>`,
  `</svg>`,
].join("");

// The options are test seams; main() passes the real ones
function createDaemon({
  layout,
  stats,
  sampler,
  keyImage,
  rasterize,
  listDecks,
  openDeck,
  runOpenIn,
  log = console.log,
  intervalMs = 2000,
  firstUpdateMs = 500,
  reconnectMs = 2000,
  alertMs = 1500,
}) {
  const known = (action) => action in PAGE_KEYS || OPEN_IN_TARGETS.has(action) || stats.isStat(action);
  for (const [page, keys] of Object.entries(layout.pages)) {
    for (const [position, action] of Object.entries(keys)) {
      if (!known(action)) log(`ERROR layout.json's ${page} page has ${action} at ${position}, which isn't an action`);
    }
  }

  let deck = null;
  let buttons = new Map();
  let page = "main";
  let connecting = false;
  let loop = null;
  let timer = null;
  let firstUpdate = null;
  let busy = false;
  let lastError = "";
  // shown holds each key's last image, so an unchanged one isn't sent again
  const shown = new Map();
  const statKeys = new Map();
  const alerts = new Set();
  const running = new Set();
  // Paths of decks whose layout this can't drive, logged once each
  const unsupported = new Set();
  // So each render error is logged once
  const failing = new Set();

  const actionAt = (index) => {
    const button = buttons.get(index);
    const action = button && layout.pages[page]?.[`${button.column},${button.row}`];
    return action && known(action) ? action : null;
  };

  // A failed write means the deck went away, as when the USB switch moves it
  function lost(error) {
    if (!deck) return;
    log(`Stream Deck disconnected: ${error?.message ?? error}`);
    const old = deck;
    deck = null;
    stopUpdates();
    shown.clear();
    alerts.clear();
    old.close().catch(() => {});
  }

  async function drawKey(index, svg) {
    if (shown.get(index) === svg) return;
    shown.set(index, svg);
    // Shown when the alert ends
    if (alerts.has(index)) return;
    await fill(index, svg);
  }

  async function fill(index, svg) {
    const current = deck;
    if (!current) return;
    try {
      const { width } = buttons.get(index).pixelSize;
      await current.fillKeyBuffer(index, rasterize(svg, width), { format: "rgba" });
    } catch (error) {
      if (deck === current) lost(error);
    }
  }

  function alert(index) {
    const current = deck;
    alerts.add(index);
    fill(index, ALERT);
    setTimeout(() => {
      alerts.delete(index);
      if (deck === current && shown.has(index)) fill(index, shown.get(index));
    }, alertMs);
  }

  // A placeholder on error, so one bad stat leaves the other keys updating
  function renderKey(kind, sample) {
    try {
      const svg = stats.render(kind, sample);
      failing.delete(kind);
      return svg;
    } catch (error) {
      if (!failing.has(kind)) log(`ERROR couldn't draw the ${kind} key: ${error.message}`);
      failing.add(kind);
      return stats.placeholder(kind);
    }
  }

  async function update() {
    if (busy || !deck || statKeys.size === 0) return;
    busy = true;
    try {
      const sample = await sampler.sample([...new Set(statKeys.values())]);
      await Promise.all([...statKeys].map(([index, kind]) => drawKey(index, renderKey(kind, sample))));
    } catch (error) {
      log(`ERROR couldn't update the stat keys: ${error.message}`);
    } finally {
      busy = false;
    }
  }

  // CPU and network are rates, so the first sample waits a moment
  function startUpdates() {
    if (timer) return;
    sampler.reset();
    timer = setInterval(update, intervalMs);
    firstUpdate = setTimeout(update, firstUpdateMs);
  }

  function stopUpdates() {
    clearInterval(timer);
    clearTimeout(firstUpdate);
    timer = null;
    sampler.stop();
  }

  // Stat keys show their icon until the first sample, as in Stream Deck
  async function showPage(name) {
    page = name;
    stopUpdates();
    statKeys.clear();
    const draws = [];
    for (const index of buttons.keys()) {
      const action = actionAt(index);
      if (action && stats.isStat(action)) statKeys.set(index, action);
      draws.push(drawKey(index, action ? keyImage(action) : BLANK));
    }
    await Promise.all(draws);
    if (statKeys.size > 0) startUpdates();
  }

  function run(target, index) {
    if (running.has(target)) return;
    if (ONE_AT_A_TIME.has(target)) running.add(target);
    runOpenIn(target, (error, output) => {
      running.delete(target);
      for (const line of output.split("\n").filter(Boolean)) log(line);
      if (error) alert(index);
    });
  }

  function press(control) {
    if (control.type !== "button") return;
    const action = actionAt(control.index);
    if (!action) return;
    if (action in PAGE_KEYS) {
      showPage(PAGE_KEYS[action]);
    } else if (stats.isStat(action)) {
      run("activity-monitor", control.index);
    } else {
      run(action, control.index);
    }
  }

  // Logs a repeated error once, so a deck it can't open isn't logged every 2 s
  function logOnce(message) {
    if (message !== lastError) log(message);
    lastError = message;
  }

  async function connect() {
    if (deck || connecting) return;
    connecting = true;
    try {
      for (const info of await listDecks()) {
        if (unsupported.has(info.path)) continue;
        let opened;
        try {
          opened = await openDeck(info.path);
        } catch (error) {
          logOnce(`ERROR couldn't open the Stream Deck at ${info.path}: ${error.message}`);
          continue;
        }
        const keys = opened.CONTROLS.filter((c) => c.type === "button" && c.feedbackType === "lcd");
        const columns = Math.max(...keys.map((c) => c.column)) + 1;
        const rows = Math.max(...keys.map((c) => c.row)) + 1;
        if (columns !== layout.columns || rows !== layout.rows) {
          log(`The ${opened.PRODUCT_NAME} has ${columns}×${rows} keys; layout.json is for ${layout.columns}×${layout.rows}`);
          unsupported.add(info.path);
          await opened.close().catch(() => {});
          continue;
        }
        deck = opened;
        lastError = "";
        buttons = new Map(keys.map((c) => [c.index, c]));
        shown.clear();
        opened.on("down", press);
        opened.on("error", (error) => {
          if (deck === opened) lost(error);
        });
        log(`Stream Deck connected: ${opened.PRODUCT_NAME}`);
        await opened.setBrightness(layout.brightness);
        await showPage("main");
        return;
      }
    } catch (error) {
      logOnce(`ERROR couldn't look for a Stream Deck: ${error.message}`);
      if (deck) lost(error);
    } finally {
      connecting = false;
    }
  }

  function start() {
    loop = setInterval(connect, reconnectMs);
    return connect();
  }

  // Leaves the deck showing its logo, as Stream Deck does when it quits
  async function stop() {
    clearInterval(loop);
    stopUpdates();
    const current = deck;
    deck = null;
    if (!current) return;
    await current.resetToLogo().catch(() => {});
    await current.close().catch(() => {});
  }

  return { start, stop, state: () => ({ connected: Boolean(deck), page }) };
}

// The key's icon from the plugin's images: SVG, or the 144 px PNG wrapped in SVG
function imageLoader(dir) {
  const cache = new Map();
  return (action) => {
    if (!cache.has(action)) {
      const svg = path.join(dir, `key-${action}.svg`);
      const png = path.join(dir, `key-${action}@2x.png`);
      if (fs.existsSync(svg)) {
        cache.set(action, fs.readFileSync(svg, "utf8"));
      } else if (fs.existsSync(png)) {
        const data = fs.readFileSync(png).toString("base64");
        cache.set(
          action,
          `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><image width="144" height="144" href="data:image/png;base64,${data}"/></svg>`,
        );
      } else {
        cache.set(action, BLANK);
      }
    }
    return cache.get(action);
  };
}

function main() {
  const { listStreamDecks, openStreamDeck } = require("@elgato-stream-deck/node");
  const { Resvg } = require("@resvg/resvg-js");
  const stats = require("./stats.js");
  const layout = JSON.parse(fs.readFileSync(path.join(__dirname, "layout.json"), "utf8"));
  const openIn = path.join(__dirname, "bin", "open-in");
  const log = (message) => console.log(message);
  // resvg doesn't read fontconfig's aliases, so the keys' Helvetica would fall back to a serif. This
  // asks for the closest font that has the symbols the keys draw: ↑ ↓ ° · … —.
  let sans = "DejaVu Sans";
  try {
    sans = require("node:child_process").execFileSync(
      "fc-match",
      ["-f", "%{family[0]}", "Helvetica:charset=2191 2193 b0 b7 2026 2014"],
      { encoding: "utf8" },
    );
  } catch {
    // fontconfig ships with Ubuntu's desktop; the default stays
  }
  const font = { loadSystemFonts: true, defaultFontFamily: sans, sansSerifFamily: sans };
  const daemon = createDaemon({
    layout,
    stats,
    sampler: stats.createSampler({ log }),
    keyImage: imageLoader(path.join(__dirname, "images")),
    rasterize: (svg, size) => new Resvg(svg, { fitTo: { mode: "width", value: size }, font }).render().pixels,
    listDecks: listStreamDecks,
    openDeck: (devicePath) => openStreamDeck(devicePath, { resetToLogoOnClose: false }),
    runOpenIn: (target, done) =>
      execFile("/bin/bash", [openIn, target], { env: { ...process.env, OPEN_IN_CALLER: "Stream Deck" } }, (error, stdout, stderr) =>
        done(error, `${stdout}${stderr}`),
      ),
    log,
  });
  for (const signal of ["SIGTERM", "SIGINT"]) {
    process.on(signal, () => daemon.stop().finally(() => process.exit(0)));
  }
  daemon.start();
}

if (require.main === module) main();

module.exports = { createDaemon, imageLoader, ALERT, BLANK };
