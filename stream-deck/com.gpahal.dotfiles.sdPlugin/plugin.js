// Uses Node's built-in WebSocket, so the plugin needs no packages.
const { execFile } = require("node:child_process");
const path = require("node:path");
const stats = require("./stats.js");

const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i === -1 ? undefined : process.argv[i + 1];
};
const pluginUUID = arg("-pluginUUID");
const OPEN_IN = path.join(__dirname, "bin", "open-in");
const INTERVAL_MS = 2000;
const socket = new WebSocket(`ws://127.0.0.1:${arg("-port")}`);
const send = (message) => socket.send(JSON.stringify(message));
const log = (message) => send({ event: "logMessage", payload: { message } });

// A second New Tab press while the first runs would open a second tab and paste twice
const ONE_AT_A_TIME = new Set(["chrome-tab"]);
const running = new Set();

function runScript(target, context) {
  if (running.has(target)) return;
  if (ONE_AT_A_TIME.has(target)) running.add(target);
  execFile("/bin/bash", [OPEN_IN, target], (error, stdout, stderr) => {
    running.delete(target);
    for (const line of `${stdout}${stderr}`.split("\n").filter(Boolean)) log(line);
    if (error) send({ event: "showAlert", context });
  });
}

// shown holds each key's last image, so an unchanged one isn't sent again
const visible = new Map();
const shown = new Map();
const sampler = stats.createSampler({ log });
let timer = null;
let busy = false;

// So each render error is logged once
const failing = new Set();

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

// CPU and network are rates, so the first sample waits a moment
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

// The bundled System profile is for the 15-key model only; switching to it elsewhere does nothing
const STREAM_DECK_15_KEY = 0;
const deviceTypes = new Map();

socket.onopen = () => send({ event: arg("-registerEvent"), uuid: pluginUUID });
socket.onclose = () => {
  sampler.stop();
  process.exit(0);
};
socket.onmessage = ({ data }) => {
  // An exception here would end the plugin
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
  const target = action.slice(action.lastIndexOf(".") + 1);
  // A reappearing key shows its default image, so it needs the stat again
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
