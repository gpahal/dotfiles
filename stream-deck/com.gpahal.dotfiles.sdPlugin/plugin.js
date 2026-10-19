// Runs bin/open-in for each key press of the plugin's actions, shows a warning on the key when it
// fails, and passes what it printed to Stream Deck's log, which Stream Deck writes to
// ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log. Stream Deck starts this with -port,
// -pluginUUID, and -registerEvent, and Node 24's built-in WebSocket talks to it, so the plugin
// needs no packages.
//
// The stat keys, which stats.js draws, update every 2 seconds while one is on screen. Overview
// switches to profiles/System, the page of stat keys the plugin bundles for the 15-key model, and
// Back returns to the profile before it. Pressing a stat key opens Activity Monitor.
const { execFile } = require("node:child_process");
const path = require("node:path");
const stats = require("./stats.js");

const arg = (name) => process.argv[process.argv.indexOf(name) + 1];
const pluginUUID = arg("-pluginUUID");
const OPEN_IN = path.join(__dirname, "bin", "open-in");
const INTERVAL_MS = 2000;
const socket = new WebSocket(`ws://127.0.0.1:${arg("-port")}`);
const send = (message) => socket.send(JSON.stringify(message));
const log = (message) => send({ event: "logMessage", payload: { message } });

// The targets whose open-in still runs, of those a second press would repeat: a second New Tab
// press while the first's tab is on its way, as while Chrome starts, would open a second tab and
// paste twice, so it's dropped, as the Hammerspoon hotkey drops it
const ONE_AT_A_TIME = new Set(["chrome-tab"]);
const running = new Set();

// open-in's targets are the actions' names; it fails, so the key shows a warning, for any other
function runScript(target, context) {
  if (running.has(target)) return;
  if (ONE_AT_A_TIME.has(target)) running.add(target);
  execFile("/bin/bash", [OPEN_IN, target], (error, stdout, stderr) => {
    running.delete(target);
    for (const line of `${stdout}${stderr}`.split("\n").filter(Boolean)) log(line);
    if (error) send({ event: "showAlert", context });
  });
}

// The stat keys on screen, by context, with what each shows, and the image each was last sent.
// Most keys, such as Disk and Swap, rarely change, so an unchanged image isn't sent again.
const visible = new Map();
const shown = new Map();
const sampler = stats.createSampler({ log });
let timer = null;
let busy = false;

// The kinds whose last render threw, so each error is logged once rather than every 2 seconds
const failing = new Set();

// A key's SVG, or its placeholder when rendering throws, so one bad stat, such as a field a macmon
// update renamed, leaves the other keys updating
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
  if (busy || visible.size === 0) return;
  busy = true;
  try {
    const sample = await sampler.sample([...new Set(visible.values())]);
    for (const [context, kind] of visible) {
      const image = `data:image/svg+xml;charset=utf8,${encodeURIComponent(renderKey(kind, sample))}`;
      if (shown.get(context) === image) continue;
      shown.set(context, image);
      send({ event: "setImage", context, payload: { image } });
    }
  } catch (error) {
    log(`ERROR couldn't update the stat keys: ${error.message}`);
  } finally {
    busy = false;
  }
}

// The first sample waits a moment, since CPU and network are rates over the time between samples
function startUpdates() {
  if (timer) return;
  sampler.reset();
  timer = setInterval(update, INTERVAL_MS);
  setTimeout(update, 500);
}

function stopUpdates() {
  clearInterval(timer);
  timer = null;
  sampler.stop();
}

// Each connected device's type, from Stream Deck's deviceDidConnect. The bundled System profile is
// for the 15-key model alone (DeviceType 0 in the manifest), and switching to it on any other
// device does nothing, so Overview shows a warning there instead.
const STREAM_DECK_15_KEY = 0;
const deviceTypes = new Map();

socket.onopen =() => send({ event: arg("-registerEvent"), uuid: pluginUUID });
socket.onclose = () => {
  sampler.stop();
  process.exit(0);
};
socket.onmessage = ({ data }) => {
  // An exception here would end the plugin, every key with it
  let message;
  try {
    message = JSON.parse(data);
  } catch (error) {
    log(`ERROR couldn't read a message from Stream Deck: ${error.message}`);
    return;
  }
  const { event, action, context, device } = message;
  if (event === "deviceDidConnect") deviceTypes.set(device, message.deviceInfo?.type);
  if (event === "deviceDidDisconnect") deviceTypes.delete(device);
  if (!action) return;
  // com.gpahal.dotfiles.files is files
  const target = action.slice(action.lastIndexOf(".") + 1);
  // Stream Deck shows a key's default image when it reappears, so it needs the stat again
  if (event === "willAppear" || event === "willDisappear") shown.delete(context);
  if (event === "willAppear" && stats.isStat(target)) {
    visible.set(context, target);
    startUpdates();
  } else if (event === "willDisappear" && visible.delete(context) && visible.size === 0) {
    stopUpdates();
  } else if (event === "keyDown") {
    if (target === "overview" && deviceTypes.has(device) && deviceTypes.get(device) !== STREAM_DECK_15_KEY) {
      log(`Overview's System page is laid out for the 15-key Stream Deck, not device type ${deviceTypes.get(device)}`);
      send({ event: "showAlert", context });
    } else if (target === "overview") {
      send({ event: "switchToProfile", context: pluginUUID, device, payload: { profile: "profiles/System" } });
    } else if (target === "back") {
      // With no profile named, Stream Deck returns to the one before
      send({ event: "switchToProfile", context: pluginUUID, device, payload: {} });
    } else if (stats.isStat(target)) {
      runScript("activity-monitor", context);
    } else {
      runScript(target, context);
    }
  }
};
