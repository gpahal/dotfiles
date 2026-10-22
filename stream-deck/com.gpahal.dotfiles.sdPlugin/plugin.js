// Uses Node's built-in WebSocket, so the plugin needs no packages. layout.json's pages are the
// bundled profiles/<Page>.streamDeckProfile that build-profile.sh makes.
const { execFile } = require("node:child_process");
const path = require("node:path");
const keys = require("./keys.js");
const layout = require("./layout.json");
const stats = require("./stats.js");

const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i === -1 ? undefined : process.argv[i + 1];
};
const pluginUUID = arg("-pluginUUID");
const OPEN_IN = path.join(__dirname, "bin", "open-in");
const socket = new WebSocket(`ws://127.0.0.1:${arg("-port")}`);
const send = (message) => socket.send(JSON.stringify(message));
const log = (message) => send({ event: "logMessage", payload: { message } });

const run = keys.createRunner({
  log,
  runOpenIn: (target, done) => execFile("/bin/bash", [OPEN_IN, target], (error, stdout, stderr) => done(error, `${stdout}${stderr}`)),
});

// shown holds each key's last image, so an unchanged one isn't sent again
const shown = new Map();
const sampler = stats.createSampler({ log });
const statKeys = keys.createStatKeys({
  stats,
  sampler,
  log,
  draw: (context, svg) => {
    const image = `data:image/svg+xml;charset=utf8,${encodeURIComponent(svg)}`;
    if (shown.get(context) === image) return;
    shown.set(context, image);
    send({ event: "setImage", context, payload: { image } });
  },
});

const profile = (page) => `profiles/${page[0].toUpperCase()}${page.slice(1)}`;
const switchTo = (device, page) => send({ event: "switchToProfile", context: pluginUUID, device, payload: { profile: profile(page) } });

// The profiles are laid out for one size of deck; switching to them on another does nothing
const sizes = new Map();
const fits = (device) => sizes.get(device)?.columns === layout.columns && sizes.get(device)?.rows === layout.rows;

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
  // At Stream Deck's start, and when the USB switch brings the deck back
  if (event === "deviceDidConnect") {
    sizes.set(device, message.deviceInfo?.size);
    if (fits(device)) switchTo(device, "main");
  }
  if (event === "deviceDidDisconnect") sizes.delete(device);
  if (!action) return;
  const target = action.slice(action.lastIndexOf(".") + 1);
  // A reappearing key shows its default image, so it needs the stat again
  if (event === "willAppear" || event === "willDisappear") shown.delete(context);
  if (event === "willAppear" && stats.isStat(target)) {
    statKeys.keys.set(context, target);
    statKeys.start();
  } else if (event === "willDisappear" && statKeys.keys.delete(context) && statKeys.keys.size === 0) {
    statKeys.stop();
  } else if (event === "keyDown") {
    const size = sizes.get(device);
    if (target in layout.links && !fits(device)) {
      log(`The dotfiles pages are laid out for ${layout.columns}×${layout.rows} keys, not ${size ? `${size.columns}×${size.rows}` : "this device's"}`);
      send({ event: "showAlert", context });
    } else if (target in layout.links) {
      switchTo(device, layout.links[target]);
    } else if (stats.isStat(target)) {
      run("activity-monitor", () => send({ event: "showAlert", context }));
    } else {
      run(target, () => send({ event: "showAlert", context }));
    }
  }
};
