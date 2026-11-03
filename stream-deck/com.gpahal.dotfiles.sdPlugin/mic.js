// The Mic key's inputs: reads the sound input in use and whether it's muted, switches to the next
// input, and mutes or unmutes it. macOS lists and switches inputs with SwitchAudioSource, from the
// Brewfile, and mutes by setting the input's volume to 0, since many mics, such as the Mac's own,
// have no mute control; the volume it had is kept in a state file to unmute to. Ubuntu asks PipeWire
// with pw-dump and wpctl, and uses the source's own mute.
const { execFile } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { routeUnplugged } = require("./sound.js");

// Apps' virtual inputs, such as Zoom's or an aggregate device, aren't mics to switch to
const VIRTUAL = /zoom|teams|blackhole|aggregate|loopback|soundflower|krisp|background music|virtual|\bndi\b|\bobs\b|cadefault/i;

const SWITCH_AUDIO = "/opt/homebrew/bin/SwitchAudioSource";
const OSASCRIPT = "/usr/bin/osascript";
const PW_DUMP = "/usr/bin/pw-dump";
const WPCTL = "/usr/bin/wpctl";
const STATE_FILE = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local", "state"), "dotfiles", "mic-volumes.json");
// What an unmute sets when no volume was kept
const UNMUTE_VOLUME = 75;

// The key's top line: the Mac's own mic is MAC; others are named without words every mic shares
function inputLabel(name) {
  if (/macbook|built-?in/i.test(name)) return "MAC";
  const words = name
    .replace(/\b(microphone|mic|usb|audio|input|digital|analog|stereo|mono)\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toUpperCase();
  if (!words) return "MIC";
  return words.length > 11 ? `${words.slice(0, 10)}…` : words;
}

// SwitchAudioSource -f json prints one object a line: {"name", "type", "id", "uid"}
function parseSwitchAudio(text) {
  const devices = [];
  for (const line of text.split("\n")) {
    try {
      const { id, name, uid } = JSON.parse(line);
      if (!VIRTUAL.test(`${name} ${uid}`)) devices.push({ id: String(id), name, label: inputLabel(name) });
    } catch {
      // A blank line
    }
  }
  return devices;
}

// pw-dump's Audio/Source nodes but virtual ones and those whose jack is unplugged, the default
// metadata's default.audio.source, the one in use, and whether it's muted
function parsePwDump(text) {
  const objects = JSON.parse(text);
  const unplugged = routeUnplugged(objects, "Input");
  const devices = [];
  let currentName = null;
  for (const object of objects) {
    const props = object.info?.props ?? {};
    const name = props["node.description"] ?? props["node.name"] ?? String(object.id);
    if (
      props["media.class"] === "Audio/Source" &&
      !props["node.virtual"] &&
      !VIRTUAL.test(`${props["node.name"]} ${name}`) &&
      !unplugged.has(`${props["device.id"]}/${props["card.profile.device"]}`)
    ) {
      const muted = (object.info?.params?.Props ?? []).some((p) => p.mute === true);
      devices.push({ id: String(object.id), name, label: inputLabel(name), node: props["node.name"], muted });
    }
    if (object.type === "PipeWire:Interface:Metadata" && object.props?.["metadata.name"] === "default") {
      const entry = object.metadata?.find((m) => m.key === "default.audio.source");
      currentName = entry?.value?.name ?? currentName;
    }
  }
  const current = devices.find((d) => d.node === currentName) ?? null;
  return { devices, current: current?.id ?? null, muted: current?.muted ?? false };
}

// The input after the current one, wrapping; null when there's nowhere else to go
function nextInput(inputs, current) {
  const i = inputs.findIndex((d) => d.id === current);
  const next = inputs[(i + 1) % inputs.length];
  return next && next.id !== current ? next : null;
}

const exec = (file, args) =>
  new Promise((resolve) =>
    execFile(file, args, { timeout: 2000, maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) =>
      resolve({ error, stdout, stderr }),
    ),
  );

// The options are test seams
function createMic({
  log = () => {},
  platform = process.platform,
  runCommand = exec,
  exists = fs.existsSync,
  stateFile = STATE_FILE,
  switchAudio = SWITCH_AUDIO,
  osascript = OSASCRIPT,
  pwDump = PW_DUMP,
  wpctl = WPCTL,
} = {}) {
  const linux = platform === "linux";
  // Each new error is logged once, so a failing command isn't logged every 2 s
  let lastError = null;
  let queue = Promise.resolve();

  function failed(message) {
    if (message !== lastError) log(`ERROR couldn't read the mic: ${message}`);
    lastError = message;
    return null;
  }

  // The default input's volume, 0 to 100, or null when it has none
  async function macVolume() {
    const { error, stdout } = await runCommand(osascript, ["-e", "input volume of (get volume settings)"]);
    const volume = Number(stdout?.trim());
    return error || stdout?.trim() === "" || Number.isNaN(volume) ? null : volume;
  }

  // { inputs, current, name, muted } with current the ID in use; { missing } naming what to
  // install; or null when a command failed
  async function read() {
    if (!exists(linux ? pwDump : switchAudio)) {
      const missing = linux ? "pipewire-bin" : "switchaudio-osx";
      failed(`it needs ${missing}`);
      return { missing };
    }
    let inputs;
    let current;
    let muted;
    if (linux) {
      const { error, stdout } = await runCommand(pwDump, []);
      if (error) return failed(error.message);
      try {
        ({ devices: inputs, current, muted } = parsePwDump(stdout));
      } catch (e) {
        return failed(`pw-dump printed something else: ${e.message}`);
      }
    } else {
      const [all, now, volume] = await Promise.all([
        runCommand(switchAudio, ["-a", "-t", "input", "-f", "json"]),
        runCommand(switchAudio, ["-c", "-t", "input", "-f", "json"]),
        macVolume(),
      ]);
      if (all.error || now.error) return failed((all.error ?? now.error).message);
      inputs = parseSwitchAudio(all.stdout);
      // The current input even when it's virtual, so the key can name it
      try {
        const line = JSON.parse(now.stdout.split("\n")[0]);
        current = String(line.id);
        if (!inputs.some((d) => d.id === current)) inputs.unshift({ id: current, name: line.name, label: inputLabel(line.name), virtual: true });
      } catch {
        current = null;
      }
      muted = volume === 0;
    }
    lastError = null;
    const name = inputs.find((d) => d.id === current)?.name ?? null;
    return { inputs: inputs.filter((d) => !d.virtual || d.id === current), current, name, muted };
  }

  async function switchNext() {
    const state = await read();
    if (!state || state.missing) return false;
    const next = nextInput(state.inputs.filter((d) => !d.virtual), state.current);
    if (!next) {
      log(`mic: no other input to switch to from ${state.name ?? "none"}`);
      return false;
    }
    const { error, stderr } = linux
      ? await runCommand(wpctl, ["set-default", next.id])
      : await runCommand(switchAudio, ["-t", "input", "-i", next.id]);
    if (error) {
      log(`ERROR couldn't switch the mic to ${next.name}: ${(stderr || error.message).trim()}`);
      return false;
    }
    log(`mic: switched from ${state.name ?? "none"} to ${next.name}`);
    return true;
  }

  function readVolumes() {
    try {
      return JSON.parse(fs.readFileSync(stateFile, "utf8"));
    } catch {
      return {};
    }
  }

  function keepVolume(name, volume) {
    try {
      fs.mkdirSync(path.dirname(stateFile), { recursive: true });
      fs.writeFileSync(stateFile, `${JSON.stringify({ ...readVolumes(), [name]: volume })}\n`);
    } catch (error) {
      log(`ERROR couldn't keep the mic's volume in ${stateFile}: ${error.message}`);
    }
  }

  async function toggle() {
    const state = await read();
    if (!state || state.missing || state.current == null) return false;
    const name = state.name ?? "the mic";
    if (linux) {
      const { error, stderr } = await runCommand(wpctl, ["set-mute", state.current, "toggle"]);
      if (error) {
        log(`ERROR couldn't mute or unmute ${name}: ${(stderr || error.message).trim()}`);
        return false;
      }
    } else {
      const volume = await macVolume();
      if (volume == null) {
        log(`mic: ${name} has no volume to mute it with`);
        return false;
      }
      let target = 0;
      if (volume === 0) {
        target = readVolumes()[name] || UNMUTE_VOLUME;
      } else {
        keepVolume(name, volume);
      }
      const { error, stderr } = await runCommand(osascript, ["-e", `set volume input volume ${target}`]);
      if (error) {
        log(`ERROR couldn't mute or unmute ${name}: ${(stderr || error.message).trim()}`);
        return false;
      }
    }
    log(`mic: ${state.muted ? "unmuted" : "muted"} ${name}`);
    return true;
  }

  // One change at a time, so a quick second press reads what the first changed
  const serial = (fn) => () => {
    queue = queue.then(fn, fn);
    return queue;
  };

  return { read, cycle: serial(switchNext), toggleMute: serial(toggle) };
}

module.exports = { createMic, inputLabel, nextInput, parsePwDump, parseSwitchAudio };
