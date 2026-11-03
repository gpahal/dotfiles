#!/bin/bash

# The Mic key: mic.js's parsers, its macOS and Ubuntu reads, switches, and mutes with fake
# commands, and stats.js's drawing of the key.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v node &> /dev/null || skip "node isn't installed"
PLUGIN_SRC="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin"

# Runs $1 with m (mic.js), stats (stats.js), logs, runs (each fake command's file and args), and
# stateFile, where the macOS mute keeps volumes
mic_js() {
    node -e "(async () => {
const m = require(process.argv[1] + '/mic.js');
const stats = require(process.argv[1] + '/stats.js');
const logs = [];
const log = (message) => logs.push(message);
const runs = [];
const stateFile = process.argv[2] + '/state/mic-volumes.json';
$1
})().catch((e) => { console.error(e); process.exit(1); });" "$PLUGIN_SRC" "$SANDBOX"
}

# Each input is named without the words every mic shares, cut to 11 characters; the Mac's own is MAC
out="$(mic_js 'console.log(["MacBook Pro Microphone", "Shure MV7", "USB Audio Microphone", "USB Audio Line Input",
  "Elgato Wave:3 Digital Microphone", "Logitech BRIO"].map(m.inputLabel).join("|"));')"
assert_eq "MAC|SHURE MV7|MIC|LINE|ELGATO WAV…|LOGITECH B…" "$out" "the inputs' labels"

# SwitchAudioSource's inputs less apps' virtual ones
switch_audio='{"name": "MacBook Pro Microphone", "type": "input", "id": "81", "uid": "BuiltInMicrophoneDevice"}
{"name": "ZoomAudioDevice", "type": "input", "id": "60", "uid": "zoom.us.zoomaudiodevice.001"}
{"name": "Shure MV7", "type": "input", "id": "90", "uid": "AppleUSBAudioEngine:Shure Inc:Shure MV7:1"}
{"name": "Microsoft Teams Audio", "type": "input", "id": "61", "uid": "MSLoopbackDriverDevice_UID"}
'
out="$(SA="$switch_audio" mic_js 'const inputs = m.parseSwitchAudio(process.env.SA);
console.log(inputs.map((d) => `${d.label}=${d.id}`).join(" "));
console.log(m.nextInput(inputs, "81").id, m.nextInput(inputs, "90").id, m.nextInput(inputs, "60").id, m.nextInput([inputs[0]], "81"));')"
assert_eq "MAC=81 SHURE MV7=90
90 81 81 null" "$out" "the macOS inputs, and the next of each"

# PipeWire's sources less virtual ones and those whose jack is unplugged, with the default's mute
pw_dump='[
 {"id": 58, "type": "PipeWire:Interface:Device", "info": {"params": {"EnumRoute": [
   {"direction": "Input", "available": "no", "devices": [13]},
   {"direction": "Input", "available": "yes", "devices": [14]},
   {"direction": "Output", "available": "no", "devices": [11]}]}}},
 {"id": 45, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source",
   "node.name": "alsa_input.usb-Generic_USB_Audio-00.HiFi__Line__source", "node.description": "USB Audio Line Input",
   "device.id": 58, "card.profile.device": 13}}},
 {"id": 44, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source",
   "node.name": "alsa_input.usb-Generic_USB_Audio-00.HiFi__Mic__source", "node.description": "USB Audio Microphone",
   "device.id": 58, "card.profile.device": 14}, "params": {"Props": [{"mute": false}]}}},
 {"id": 50, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source",
   "node.name": "alsa_input.usb-Shure_MV7-00.mono-fallback", "node.description": "Shure MV7 Mono"},
   "params": {"Props": [{"volume": 1}, {"mute": true}]}}},
 {"id": 51, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source",
   "node.name": "effect_input.rnnoise", "node.description": "Noise Canceling Source", "node.virtual": true}}},
 {"id": 41, "type": "PipeWire:Interface:Metadata", "props": {"metadata.name": "default"}, "metadata": [
   {"subject": 0, "key": "default.audio.source", "type": "Spa:String:JSON", "value": {"name": "alsa_input.usb-Shure_MV7-00.mono-fallback"}}]}
]'
out="$(PW="$pw_dump" mic_js 'const { devices, current, muted } = m.parsePwDump(process.env.PW);
console.log(devices.map((d) => `${d.label}=${d.id}`).join(" "), current, muted);')"
assert_eq "MIC=44 SHURE MV7=50 50 true" "$out" "the Ubuntu sources, the one in use, and its mute"

# macOS: switches with SwitchAudioSource, and mutes by setting the input's volume to 0, keeping
# the volume it had to unmute to. A virtual input in use is named but not switched to.
out="$(SA="$switch_audio" mic_js 'let current = "81";
let volume = 60;
const runCommand = async (file, args) => {
  const cmd = file.split("/").pop();
  runs.push([cmd, ...args].join(" "));
  if (cmd === "osascript") {
    if (args[1].startsWith("set volume")) { volume = Number(args[1].split(" ").pop()); return { stdout: "" }; }
    return { stdout: `${volume}\n` };
  }
  if (args[0] === "-a") return { stdout: process.env.SA };
  if (args[0] === "-c") return { stdout: process.env.SA.split("\n").find((l) => l.includes(`"${current}"`)) };
  if (args[0] === "-t") { current = args[3]; return { stdout: "" }; }
};
const mic = m.createMic({ log, platform: "darwin", runCommand, exists: () => true, stateFile });
let s = await mic.read();
console.log(s.inputs.map((d) => d.label).join(), s.current, s.muted);
console.log(await mic.cycle(), current);
console.log(await mic.toggleMute(), volume, (await mic.read()).muted, require("fs").readFileSync(stateFile, "utf8").trim());
console.log(await mic.toggleMute(), volume, (await mic.read()).muted);
current = "60";
s = await mic.read();
console.log(s.inputs.map((d) => d.label).join(), s.current);
console.log(await mic.cycle(), current);
console.log(logs.join("\n"));')"
assert_eq 'MAC,SHURE MV7 81 false
true 90
true 0 true {"Shure MV7":60}
true 60 false
ZOOMAUDIOD…,MAC,SHURE MV7 60
true 81
mic: switched from MacBook Pro Microphone to Shure MV7
mic: muted Shure MV7
mic: unmuted Shure MV7
mic: switched from ZoomAudioDevice to MacBook Pro Microphone' "$out" "switching and muting on macOS"

# Ubuntu: switches and mutes with wpctl
out="$(PW="$pw_dump" mic_js 'const runCommand = async (file, args) => {
  runs.push([file.split("/").pop(), ...args].join(" "));
  return { stdout: file.endsWith("pw-dump") ? process.env.PW : "" };
};
const mic = m.createMic({ log, platform: "linux", runCommand, exists: () => true, stateFile });
console.log(await mic.cycle(), await mic.toggleMute());
console.log(runs.filter((r) => r.startsWith("wpctl")).join("|"));
console.log(logs.join("\n"));')"
assert_eq "true true
wpctl set-default 44|wpctl set-mute 50 toggle
mic: switched from Shure MV7 Mono to USB Audio Microphone
mic: unmuted Shure MV7 Mono" "$out" "switching and muting on Ubuntu"

# A missing command logs once and changes nothing; a Mac input with no volume can't be muted
out="$(SA="$switch_audio" mic_js 'let installed = false;
const runCommand = async (file, args) => {
  runs.push(args.join(" "));
  if (file.endsWith("osascript")) return { stdout: "missing value\n" };
  return { stdout: args[0] === "-c" ? process.env.SA.split("\n")[0] : process.env.SA };
};
const mic = m.createMic({ log, platform: "darwin", runCommand, exists: () => installed, stateFile });
console.log(JSON.stringify(await mic.read()), await mic.cycle(), await mic.toggleMute(), runs.length);
installed = true;
console.log(await mic.toggleMute(), runs.some((r) => r.startsWith("-e set")));
console.log(logs.join("\n"));')"
assert_eq '{"missing":"switchaudio-osx"} false false 0
false false
ERROR couldn'"'"'t read the mic: it needs switchaudio-osx
mic: MacBook Pro Microphone has no volume to mute it with' "$out" "a missing command, and a mic without a volume"

# The key names the input in use, green while live and red and crossed out while muted, with a
# dot for each input
out="$(mic_js 'const inputs = [{ id: "1", label: "MAC" }, { id: "2", label: "SHURE MV7" }];
const label = (svg) => /font-size="(\d+)"[^>]*>([^<]*)<\/text>/.exec(svg).slice(1).join(":");
const filled = (svg) => (svg.match(/<circle[^>]*#4ade80/g) ?? []).length + "/" + (svg.match(/<circle/g) ?? []).length;
for (const muted of [false, true]) {
  const svg = stats.render("mic", { mic: { inputs, current: "2", muted } });
  console.log(label(svg), filled(svg), svg.includes("#f87171"), svg.includes("M44 40l56 64"));
}
console.log(stats.placeholder("mic").includes(">—<"), stats.render("mic", { mic: { missing: "x" } }).includes(">not installed<"));')"
assert_eq "17:SHURE MV7 1/2 false false
17:SHURE MV7 1/2 true true
true true" "$out" "the key's drawing"

# keys.js: a tap runs onTap at the release, a hold runs onHold once without waiting for it
out="$(node -e 'const keys = require(process.argv[1]);
const calls = [];
const hold = keys.createHold({ onTap: (id) => calls.push("tap " + id), onHold: (id) => calls.push("hold " + id), holdMs: 30 });
(async () => {
  hold.down("a");
  hold.up("a");
  hold.down("b");
  await new Promise((r) => setTimeout(r, 60));
  hold.up("b");
  hold.up("c");
  console.log(calls.join(","));
})();' "$PLUGIN_SRC/keys.js" 2>&1)"
assert_eq "tap a,hold b" "$out" "tap and hold"

test_done
