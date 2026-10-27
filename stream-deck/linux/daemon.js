// Drives the Stream Deck on Ubuntu with the Mac plugin's keys. The dotfiles-stream-deck user
// service runs it from the copy the stream-deck step installs, beside bin/open-in and the plugin's
// keys.js, sound.js, stats.js, layout.json, manifest.json, and images/. layout.json places the keys, and its
// links are the keys that switch pages. It logs to the journal.
const { execFile, execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const BLANK = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><rect width="144" height="144" fill="#000"/></svg>`;
// Like Stream Deck's showAlert
const ALERT = [
  `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">`,
  `<rect width="144" height="144" fill="#18181b"/>`,
  `<path d="M72 26 124 116H20Z" fill="#facc15" stroke="#facc15" stroke-width="10" stroke-linejoin="round"/>`,
  `<rect x="66" y="56" width="12" height="34" rx="6" fill="#18181b"/><circle cx="72" cy="102" r="7" fill="#18181b"/>`,
  `</svg>`,
].join("");
// Elgato's app sets the deck's brightness on the Mac. Here it's set on each connect, since the deck
// otherwise shows whatever it was left at, which looks dull.
const BRIGHTNESS = 60;

// The options are test seams; main() passes the real ones. actions are the manifest's, keys is
// keys.js, and sound is sound.js's createSound().
function createDaemon({
  layout,
  actions,
  keys,
  stats,
  sampler,
  keyImage,
  rasterize,
  listDecks,
  openDeck,
  runOpenIn,
  sound,
  log = console.log,
  intervalMs = 2000,
  firstUpdateMs = 500,
  reconnectMs = 2000,
  alertMs = 1500,
}) {
  const known = (action) => action in layout.links || actions.has(action);
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
  let lastError = "";
  // shown holds each key's last image, so an unchanged one isn't sent again
  const shown = new Map();
  const alerts = new Set();
  // Paths of decks whose layout this can't drive, logged once each
  const unsupported = new Set();
  const statKeys = keys.createStatKeys({
    stats,
    sampler,
    log,
    draw: drawKey,
    ready: () => Boolean(deck),
    intervalMs,
    firstUpdateMs,
  });
  const run = keys.createRunner({ runOpenIn, log });

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
    statKeys.stop();
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

  // Stat keys show their icon until the first sample, as in Stream Deck
  async function showPage(name) {
    page = name;
    statKeys.stop();
    statKeys.keys.clear();
    const draws = [];
    for (const index of buttons.keys()) {
      const action = actionAt(index);
      if (action && stats.isStat(action)) statKeys.keys.set(index, action);
      draws.push(drawKey(index, action ? keyImage(action) : BLANK));
    }
    await Promise.all(draws);
    if (statKeys.keys.size > 0) statKeys.start();
  }

  function press(control) {
    if (control.type !== "button") return;
    const action = actionAt(control.index);
    if (!action) return;
    if (action in layout.links) {
      showPage(layout.links[action]);
    } else if (action === "sound") {
      sound.cycle().then((switched) => (switched ? statKeys.refresh() : alert(control.index)));
    } else {
      run(stats.isStat(action) ? "activity-monitor" : action, () => alert(control.index));
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
        try {
          await opened.setBrightness(BRIGHTNESS);
        } catch (error) {
          lost(error);
          return;
        }
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
    statKeys.stop();
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

// resvg doesn't read fontconfig's aliases, so the keys' Helvetica would fall back to a serif. This
// asks fontconfig once for the closest family with the symbols the keys draw (↑ ↓ ° · … —) and
// loads only that family's files, since resvg loading every system font for each key is slow.
function fontOptions(run = (file, args) => execFileSync(file, args, { encoding: "utf8" })) {
  try {
    const family = run("fc-match", ["-f", "%{family[0]}", "Helvetica:charset=2191 2193 b0 b7 2026 2014"]).trim();
    // fontconfig's pattern syntax gives - : , and \ meanings
    const pattern = family.replace(/[-:,\\]/g, "\\$&");
    const fontFiles = run("fc-list", ["-f", "%{file}\n", pattern])
      .split("\n")
      .filter((file) => /\.(otf|ttf|otc|ttc)$/i.test(file))
      .sort();
    if (family && fontFiles.length > 0) {
      return { loadSystemFonts: false, fontFiles, defaultFontFamily: family, sansSerifFamily: family };
    }
  } catch {
    // fontconfig ships with Ubuntu's desktop
  }
  return { loadSystemFonts: true, defaultFontFamily: "DejaVu Sans", sansSerifFamily: "DejaVu Sans" };
}

function main() {
  const { listStreamDecks, openStreamDeck } = require("@elgato-stream-deck/node");
  const { Resvg } = require("@resvg/resvg-js");
  const keys = require("./keys.js");
  const { createSound } = require("./sound.js");
  const stats = require("./stats.js");
  const read = (file) => JSON.parse(fs.readFileSync(path.join(__dirname, file), "utf8"));
  const manifest = read("manifest.json");
  const openIn = path.join(__dirname, "bin", "open-in");
  const log = (message) => console.log(message);
  const font = fontOptions();
  const sound = createSound({ log });
  const daemon = createDaemon({
    layout: read("layout.json"),
    actions: new Set(manifest.Actions.map((action) => action.UUID.slice(manifest.UUID.length + 1))),
    keys,
    stats,
    sampler: stats.createSampler({ log, sound }),
    sound,
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

module.exports = { createDaemon, imageLoader, fontOptions, ALERT, BLANK };
