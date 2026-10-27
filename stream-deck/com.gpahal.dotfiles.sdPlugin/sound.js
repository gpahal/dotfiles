// The Sound key's outputs: reads the sound output in use and switches to the next. macOS has no
// command of its own for this, so it runs SwitchAudioSource, from the Brewfile; Ubuntu asks
// PipeWire with pw-dump and wpctl.
const { execFile } = require("node:child_process");
const fs = require("node:fs");

// The outputs the key cycles through, in this order, and the label each shows. Each matches a
// device's name and UID on macOS, or a PipeWire node's name and description on Ubuntu. Other
// outputs, such as S/PDIF, the jacks on Ubuntu's board, or an app's virtual device, are skipped.
const OUTPUTS = [
  { kind: "speakers", label: "SPEAKERS", match: /Pebble/i },
  { kind: "headphones", label: "HEADPHONES", match: /Protocol.?Micro/i },
  { kind: "monitor", label: "MONITOR", match: /DELL|HDMI|DisplayPort/i },
  { kind: "mac", label: "MAC", match: /MacBook.*Speakers|BuiltInSpeaker/i },
];

const SWITCH_AUDIO = "/opt/homebrew/bin/SwitchAudioSource";
const PW_DUMP = "/usr/bin/pw-dump";
const WPCTL = "/usr/bin/wpctl";

const outputFor = (device) => OUTPUTS.find((output) => output.match.test(device.match));

// SwitchAudioSource -f json prints one object a line: {"name", "type", "id", "uid"}
function parseSwitchAudio(text) {
  const devices = [];
  for (const line of text.split("\n")) {
    try {
      const { id, name, uid } = JSON.parse(line);
      devices.push({ id: String(id), name, match: `${name} ${uid}` });
    } catch {
      // A blank line
    }
  }
  return devices;
}

// pw-dump's Audio/Sink nodes, and the default metadata's default.audio.sink, the one in use.
// WirePlumber won't make a sink whose jack is unplugged the default, so those are left out: a node
// is its card's profile device, and the card's routes say whether each device's jack is.
function parsePwDump(text) {
  const objects = JSON.parse(text);
  const unplugged = new Set();
  for (const object of objects) {
    for (const route of object.info?.params?.EnumRoute ?? []) {
      if (route.direction !== "Output" || route.available !== "no") continue;
      for (const device of route.devices ?? []) unplugged.add(`${object.id}/${device}`);
    }
  }
  const devices = [];
  let currentName = null;
  for (const object of objects) {
    const props = object.info?.props ?? {};
    if (props["media.class"] === "Audio/Sink" && !unplugged.has(`${props["device.id"]}/${props["card.profile.device"]}`)) {
      const name = props["node.description"] ?? props["node.name"] ?? String(object.id);
      devices.push({ id: String(object.id), name, node: props["node.name"], match: `${props["node.name"]} ${name}` });
    }
    if (object.type === "PipeWire:Interface:Metadata" && object.props?.["metadata.name"] === "default") {
      const entry = object.metadata?.find((m) => m.key === "default.audio.sink");
      currentName = entry?.value?.name ?? currentName;
    }
  }
  return { devices, current: devices.find((d) => d.node === currentName)?.id ?? null };
}

// The known outputs present, in OUTPUTS's order, each with its kind and label
function knownOutputs(devices) {
  return devices
    .map((device) => ({ ...device, output: outputFor(device) }))
    .filter((device) => device.output)
    .sort((a, b) => OUTPUTS.indexOf(a.output) - OUTPUTS.indexOf(b.output))
    .map(({ output, ...device }) => ({ ...device, kind: output.kind, label: output.label }));
}

// The output after the current one, wrapping; the first when the current one isn't known. Null
// when there's nowhere else to go.
function nextOutput(outputs, current) {
  const i = outputs.findIndex((o) => o.id === current);
  const next = outputs[(i + 1) % outputs.length];
  return next && next.id !== current ? next : null;
}

const exec = (file, args) =>
  new Promise((resolve) =>
    execFile(file, args, { timeout: 2000, maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) =>
      resolve({ error, stdout, stderr }),
    ),
  );

// The options are test seams
function createSound({
  log = () => {},
  platform = process.platform,
  runCommand = exec,
  exists = fs.existsSync,
  switchAudio = SWITCH_AUDIO,
  pwDump = PW_DUMP,
  wpctl = WPCTL,
} = {}) {
  const linux = platform === "linux";
  // Each new error is logged once, so a failing command isn't logged every 2 s
  let lastError = null;
  let queue = Promise.resolve();

  function failed(message) {
    if (message !== lastError) log(`ERROR couldn't read the sound output: ${message}`);
    lastError = message;
    return null;
  }

  // { outputs, current, name } with current the ID in use and name its device's name; { missing }
  // naming what to install; or null when the command failed
  async function read() {
    // Checked each read, so installing it needs no restart
    if (!exists(linux ? pwDump : switchAudio)) {
      const missing = linux ? "pipewire-bin" : "switchaudio-osx";
      failed(`it needs ${missing}`);
      return { missing };
    }
    let devices;
    let current;
    if (linux) {
      const { error, stdout } = await runCommand(pwDump, []);
      if (error) return failed(error.message);
      try {
        ({ devices, current } = parsePwDump(stdout));
      } catch (e) {
        return failed(`pw-dump printed something else: ${e.message}`);
      }
    } else {
      const [all, now] = await Promise.all([
        runCommand(switchAudio, ["-a", "-t", "output", "-f", "json"]),
        runCommand(switchAudio, ["-c", "-t", "output", "-f", "json"]),
      ]);
      if (all.error || now.error) return failed((all.error ?? now.error).message);
      devices = parseSwitchAudio(all.stdout);
      current = parseSwitchAudio(now.stdout)[0]?.id ?? null;
    }
    lastError = null;
    const name = devices.find((d) => d.id === current)?.name ?? null;
    return { outputs: knownOutputs(devices), current, name };
  }

  async function switchNext() {
    const state = await read();
    if (!state) return false;
    if (state.missing) return false;
    const next = nextOutput(state.outputs, state.current);
    if (!next) {
      log(`sound: no other output to switch to from ${state.name ?? "none"}`);
      return false;
    }
    const { error, stderr } = linux
      ? await runCommand(wpctl, ["set-default", next.id])
      : await runCommand(switchAudio, ["-t", "output", "-i", next.id]);
    if (error) {
      log(`ERROR couldn't switch the sound output to ${next.name}: ${(stderr || error.message).trim()}`);
      return false;
    }
    log(`sound: switched from ${state.name ?? "none"} to ${next.name}`);
    return true;
  }

  // One switch at a time, so a quick second press reads what the first switched to
  function cycle() {
    queue = queue.then(switchNext, switchNext);
    return queue;
  }

  return { read, cycle };
}

module.exports = { OUTPUTS, createSound, knownOutputs, nextOutput, parsePwDump, parseSwitchAudio };
