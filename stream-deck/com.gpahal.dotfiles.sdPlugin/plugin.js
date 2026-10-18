// Runs bin/open-in or bin/open-app for each key press of the plugin's actions, shows a warning on
// the key when it fails, and passes what it printed to Stream Deck's log, which Stream Deck writes
// to ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log. Stream Deck starts this with
// -port, -pluginUUID, and -registerEvent, and Node 24's built-in WebSocket talks to it, so the
// plugin needs no packages.
//
// The stat keys, which stats.js draws, update every 2 seconds while one is on screen. Overview
// switches to profiles/System, the page of stat keys the plugin bundles, and Back returns to the
// profile before it. Pressing a stat key opens Activity Monitor.
const { execFile } = require("node:child_process");
const path = require("node:path");
const stats = require("./stats.js");

const arg = (name) => process.argv[process.argv.indexOf(name) + 1];
const pluginUUID = arg("-pluginUUID");
// Each action's script, by the last part of its UUID
const scripts = {
  files: "open-in",
  editor: "open-in",
  terminal: "open-in",
  claude: "open-app",
  chrome: "open-app",
  "chrome-tab": "open-app",
  gmail: "open-app",
  "t3-code": "open-app",
  "activity-monitor": "open-app",
};
const INTERVAL_MS = 2000;
const socket = new WebSocket(`ws://127.0.0.1:${arg("-port")}`);
const send = (message) => socket.send(JSON.stringify(message));
const log = (message) => send({ event: "logMessage", payload: { message } });

function runScript(target, context) {
  const script = path.join(__dirname, "bin", scripts[target]);
  execFile("/bin/bash", [script, target], (error, stdout, stderr) => {
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

async function update() {
  if (busy || visible.size === 0) return;
  busy = true;
  try {
    const sample = await sampler.sample([...new Set(visible.values())]);
    for (const [context, kind] of visible) {
      const image = `data:image/svg+xml;charset=utf8,${encodeURIComponent(stats.render(kind, sample))}`;
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

socket.onopen = () => send({ event: arg("-registerEvent"), uuid: pluginUUID });
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
    if (target === "overview") {
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
