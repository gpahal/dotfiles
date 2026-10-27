#!/bin/bash

# The Sound key: sound.js's parsers and its macOS and Ubuntu reads and switches with fake
# commands, stats.js's drawing of the key, and keys.js's refresh.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v node &> /dev/null || skip "node isn't installed"
PLUGIN_SRC="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin"

# Runs $1 with m (sound.js), stats (stats.js), logs, and runs (each fake command's file and args)
sound_js() {
    node -e "(async () => {
const m = require(process.argv[1] + '/sound.js');
const stats = require(process.argv[1] + '/stats.js');
const logs = [];
const log = (message) => logs.push(message);
const runs = [];
$1
})().catch((e) => { console.error(e); process.exit(1); });" "$PLUGIN_SRC"
}

# SwitchAudioSource's lines; the order the key cycles in is OUTPUTS's, not the devices'
switch_audio='{"name": "DELL S2722QC", "type": "output", "id": "87", "uid": "10ACD0A1"}
{"name": "Creative Pebble Pro", "type": "output", "id": "107", "uid": "AppleUSBAudioEngine:Creative Pebble Pro:2"}
{"name": "ZoomAudioDevice", "type": "output", "id": "60", "uid": "zoom.us.zoomaudiodevice.001"}
{"name": "MacBook Pro Speakers", "type": "output", "id": "75", "uid": "BuiltInSpeakerDevice"}
{"name": "Protocol Micro", "type": "output", "id": "102", "uid": "AppleUSBAudioEngine:CrinEar Technology:Protocol Micro:1"}
'
out="$(SA="$switch_audio" sound_js 'const outputs = m.knownOutputs(m.parseSwitchAudio(process.env.SA));
console.log(outputs.map((o) => `${o.label}=${o.id}`).join(" "));
const next = (current) => m.nextOutput(outputs, current)?.label ?? "none";
console.log(next("107"), next("75"), next("60"), next(null));
console.log(next.call(null, "x"), m.nextOutput([outputs[0]], "107"), m.nextOutput([], null));')"
assert_eq "SPEAKERS=107 HEADPHONES=102 MONITOR=87 MAC=75
HEADPHONES SPEAKERS SPEAKERS SPEAKERS
SPEAKERS null null" "$out" "the macOS outputs in order, and the next of each"

# Sinks whose jack is unplugged are left out, since WirePlumber won't make them the default
pw_dump='[
 {"id": 55, "type": "PipeWire:Interface:Device", "info": {"params": {"EnumRoute": [
   {"direction": "Output", "available": "unknown", "devices": [0, 10]},
   {"direction": "Output", "available": "no", "devices": [1, 11]},
   {"direction": "Input", "available": "no", "devices": [12]}]}}},
 {"id": 61, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Sink",
   "node.name": "alsa_output.usb-Generic_USB_Audio-00.HiFi__SPDIF__sink", "node.description": "USB Audio S/PDIF Output",
   "device.id": 55, "card.profile.device": 10}}},
 {"id": 62, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Sink",
   "node.name": "alsa_output.usb-Generic_USB_Audio-00.HiFi__Speaker__sink", "node.description": "USB Audio Speakers",
   "device.id": 55, "card.profile.device": 11}}},
 {"id": 70, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Sink",
   "node.name": "alsa_output.pci-0000_0c_00.1.hdmi-stereo", "node.description": "Navi 31 HDMI/DP Audio Digital Stereo (HDMI)",
   "device.id": 57, "card.profile.device": 3}}},
 {"id": 71, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Sink",
   "node.name": "alsa_output.usb-Creative_Technology_Ltd_Creative_Pebble_Pro-00.analog-stereo", "node.description": "Creative Pebble Pro Analog Stereo"}}},
 {"id": 72, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source", "node.name": "mic"}}},
 {"id": 41, "type": "PipeWire:Interface:Metadata", "props": {"metadata.name": "default"}, "metadata": [
   {"subject": 0, "key": "default.audio.sink", "type": "Spa:String:JSON", "value": {"name": "alsa_output.pci-0000_0c_00.1.hdmi-stereo"}},
   {"subject": 0, "key": "default.configured.audio.sink", "type": "Spa:String:JSON", "value": {"name": "alsa_output.usb-Generic_USB_Audio-00.HiFi__Speaker__sink"}}]}
]'
out="$(PW="$pw_dump" sound_js 'const { devices, current } = m.parsePwDump(process.env.PW);
console.log(devices.map((d) => d.id).join(), current);
console.log(m.knownOutputs(devices).map((o) => `${o.label}=${o.id}`).join(" "));')"
assert_eq "61,70,71 70
SPEAKERS=71 MONITOR=70" "$out" "the Ubuntu sinks, the one in use, and the known ones"

# Each OS reads and switches with its own commands; the next press reads what the last switched
# to, even when pressed before it finished
out="$(SA="$switch_audio" PW="$pw_dump" sound_js 'let current = "107";
let sink = "70";
const runCommand = async (file, args) => {
  runs.push([file.split("/").pop(), ...args].join(" "));
  await new Promise((r) => setTimeout(r, 5));
  if (args[0] === "-a") return { stdout: process.env.SA };
  if (args[0] === "-c") return { stdout: process.env.SA.split("\n").find((l) => l.includes(`"${current}"`)) };
  if (args[0] === "-t") { current = args[3]; return { stdout: "" }; }
  const names = { 70: "alsa_output.pci-0000_0c_00.1.hdmi-stereo", 71: "alsa_output.usb-Creative_Technology_Ltd_Creative_Pebble_Pro-00.analog-stereo" };
  if (file.endsWith("pw-dump")) return { stdout: process.env.PW.replace(`"value": {"name": "${names[70]}"}`, `"value": {"name": "${names[sink]}"}`) };
  if (args[0] === "set-default") { sink = args[1]; return { stdout: "" }; }
};
const mac = m.createSound({ log, platform: "darwin", runCommand, exists: () => true });
await Promise.all([mac.cycle(), mac.cycle()]);
console.log(current, runs.filter((r) => r.includes(" -i ")).join("|"));
runs.length = 0;
const ubuntu = m.createSound({ log, platform: "linux", runCommand, exists: () => true });
console.log(await ubuntu.cycle(), sink, runs.join("|"));
console.log(await ubuntu.cycle(), sink);
console.log(logs.join("\n"));')"
assert_eq "87 SwitchAudioSource -t output -i 102|SwitchAudioSource -t output -i 87
true 71 pw-dump|wpctl set-default 71
true 70
sound: switched from Creative Pebble Pro to Protocol Micro
sound: switched from Protocol Micro to DELL S2722QC
sound: switched from Navi 31 HDMI/DP Audio Digital Stereo (HDMI) to Creative Pebble Pro Analog Stereo
sound: switched from Creative Pebble Pro Analog Stereo to Navi 31 HDMI/DP Audio Digital Stereo (HDMI)" "$out" "switching on each OS"

# A missing command or failing read logs each new error once, and a switch fails without running
# anything; so does one with nowhere to go
out="$(SA="$switch_audio" sound_js 'let ok = false;
let installed = false;
const runCommand = async (file, args) => {
  runs.push(args.join(" "));
  if (!ok) return { error: new Error("exit 1") };
  return { stdout: args[0] === "-a" ? process.env.SA.split("\n")[1] : process.env.SA.split("\n")[1] };
};
const s = m.createSound({ log, platform: "darwin", runCommand, exists: () => installed });
console.log(JSON.stringify(await s.read()), JSON.stringify(await s.read()), await s.cycle(), runs.length);
installed = true;
console.log(await s.read(), await s.read(), await s.cycle());
ok = true;
console.log(JSON.stringify((await s.read()).outputs.map((o) => o.label)), await s.cycle());
console.log(runs.some((r) => r.startsWith("-t")));
console.log(logs.join("\n"));')"
assert_eq '{"missing":"switchaudio-osx"} {"missing":"switchaudio-osx"} false 0
null null false
["SPEAKERS"] false
false
ERROR couldn'"'"'t read the sound output: it needs switchaudio-osx
ERROR couldn'"'"'t read the sound output: exit 1
sound: no other output to switch to from Creative Pebble Pro' "$out" "a missing or failing command"

# The key shows the output in use at the top and a dot for each, an unknown one by its name, and
# a dash before the first read or without the command
out="$(SA="$switch_audio" sound_js 'const outputs = m.knownOutputs(m.parseSwitchAudio(process.env.SA));
const label = (svg) => /font-size="(\d+)"[^>]*>([^<]*)<\/text>/.exec(svg).slice(1).join(":");
const filled = (svg) => (svg.match(/<circle[^>]*#4ade80/g) ?? []).length + "/" + (svg.match(/<circle/g) ?? []).length;
for (const current of ["107", "102", "87", "75"]) {
  const svg = stats.render("sound", { sound: { outputs, current } });
  console.log(label(svg), filled(svg));
}
const zoom = stats.render("sound", { sound: { outputs, current: "60", name: "ZoomAudioDevice" } });
console.log(label(zoom), filled(zoom), zoom.includes(">ZoomAudioD…<"));
console.log(stats.placeholder("sound").includes(">—<"), stats.render("sound", { sound: { missing: "x" } }).includes(">not installed<"));')"
assert_eq "19:SPEAKERS 1/4
17:HEADPHONES 1/4
19:MONITOR 1/4
19:MAC 1/4
19:SOUND 0/4 true
true true" "$out" "the key's drawing"

# keys.js: refresh draws at once, and a refresh during an update draws again after it
out="$(node -e 'const keys = require(process.argv[1]);
let n = 0;
let release = null;
const sampler = { reset() {}, stop() {}, async sample() { n++; if (n === 1) await new Promise((r) => (release = r)); return n; } };
const drawn = [];
const k = keys.createStatKeys({ stats: { render: (kind, s) => s }, sampler, log: console.log,
  draw: (id, svg) => drawn.push(svg), intervalMs: 60000, firstUpdateMs: 60000 });
k.keys.set("a", "sound");
(async () => {
  k.refresh();
  k.refresh();
  k.refresh();
  release();
  const deadline = Date.now() + 5000;
  while (drawn.length < 2 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 5));
  await new Promise((r) => setTimeout(r, 20));
  console.log(drawn.join());
  process.exit(0);
})();' "$PLUGIN_SRC/keys.js" 2>&1)"
assert_eq "1,2" "$out" "refresh"

test_done
