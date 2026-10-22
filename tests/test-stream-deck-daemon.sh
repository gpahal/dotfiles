#!/bin/bash
set -euo pipefail
# serial

# The Ubuntu Stream Deck daemon, with a fake deck, sampler, and open-in, the plugin's layout.json,
# and the fonts it hands resvg.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
command -v node &> /dev/null || skip "node isn't installed"
DAEMON="$REPO_DIR/stream-deck/linux/daemon.js"
PLUGIN_SRC="$REPO_DIR/stream-deck/com.gpahal.dotfiles.sdPlugin"

# Runs $1 with: d (the daemon), decks (what listDecks finds), deck() (a fake 5×3 deck), drawn(i)
# (key i's last image), runs (open-in targets), logs, and until(what, test).
daemon_js() {
    node -e "(async () => {
const { EventEmitter } = require('node:events');
const { createDaemon, ALERT, BLANK } = require(process.argv[1]);
const plugin = process.argv[2];
const realStats = require(plugin + '/stats.js');
const layout = require(plugin + '/layout.json');
const manifest = require(plugin + '/manifest.json');
const actions = new Set(manifest.Actions.map((a) => a.UUID.split('.').pop()));
const logs = [];
const runs = [];
const pending = [];
let n = 0;
const sampler = { resets: 0, stops: 0, kinds: [], reset() { this.resets++; }, stop() { this.stops++; },
  async sample(kinds) { this.kinds = kinds; return { n: ++n }; } };
const stats = { isStat: realStats.isStat, placeholder: (k) => 'placeholder:' + k,
  render: (k, s) => { if (k === 'disk') throw new Error('broken'); return 'stat:' + k + ':' + s.n; } };
const fills = [];
const deck = (columns = 5, rows = 3) => {
  const d = new EventEmitter();
  d.PRODUCT_NAME = 'Stream Deck MK.2';
  d.CONTROLS = [];
  for (let row = 0; row < rows; row++)
    for (let column = 0; column < columns; column++)
      d.CONTROLS.push({ type: 'button', feedbackType: 'lcd', index: row * columns + column, row, column, pixelSize: { width: 72, height: 72 } });
  d.log = [];
  d.fail = false;
  d.fillKeyBuffer = async (i, svg) => { if (d.fail) throw new Error('write failed'); fills.push([d, i, svg]); };
  d.close = async () => d.log.push('close');
  d.resetToLogo = async () => d.log.push('logo');
  return d;
};
let decks = [];
const opened = [];
const drawn = (i, d = opened.at(-1)) => fills.filter((f) => f[0] === d && f[1] === i).at(-1)?.[2];
const count = (i, d = opened.at(-1)) => fills.filter((f) => f[0] === d && f[1] === i).length;
const until = async (what, test) => {
  const deadline = Date.now() + 5000;
  while (!test()) {
    if (Date.now() > deadline) { console.log('timed out waiting for ' + what + '; logs: ' + JSON.stringify(logs)); process.exit(1); }
    await new Promise((r) => setTimeout(r, 5));
  }
};
const press = (i) => opened.at(-1).emit('down', { type: 'button', index: i });
const d = createDaemon({
  layout, actions, keys: require(plugin + '/keys.js'), stats, sampler,
  keyImage: (a) => 'icon:' + a,
  rasterize: (svg) => svg,
  listDecks: async () => decks.map((x, i) => ({ path: '/dev/hidraw' + i })),
  openDeck: async (p) => { const x = decks[Number(p.slice(11))]; opened.push(x); return x; },
  runOpenIn: (target, done) => { runs.push(target); pending.push(done); if (target !== 'chrome-tab') done(target === 'files' ? new Error('exit 1') : null, target + ' ran\n'); },
  log: (m) => logs.push(m),
  intervalMs: 40, firstUpdateMs: 10, reconnectMs: 20, alertMs: 30,
});
$1
process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });" "$DAEMON" "$PLUGIN_SRC"
}

# The main page: icons where layout.json puts actions, blank keys elsewhere, then Overview's stats
out="$(daemon_js "decks = [deck()];
await d.start();
console.log(JSON.stringify(d.state()), opened[0].log.length);
console.log([0, 1, 2, 3, 4, 5, 9, 10].map((i) => drawn(i) === BLANK ? 'blank' : drawn(i)).join(' '));
await until('Overview stats', () => drawn(0)?.startsWith('stat:'));
console.log(drawn(0), sampler.kinds.join(), sampler.resets);")"
assert_eq '{"connected":true,"page":"main"} 0
icon:overview icon:editor icon:terminal icon:files blank icon:chrome icon:claude blank
stat:overview:1 overview 1' "$out" "the main page"

# Overview opens the System page and Back returns; stat keys open Resources; unchanged images
# aren't sent again; one bad stat leaves the others updating
out="$(daemon_js "decks = [deck()];
await d.start();
press(0);
await until('the System page', () => drawn(1)?.startsWith('stat:cpu'));
console.log(d.state().page, drawn(0), drawn(5), drawn(14) === BLANK, sampler.kinds.join());
await until('a later sample', () => drawn(1) !== 'stat:cpu:' + sampler.kinds.length && n >= 3);
console.log(count(0) === 2, drawn(9), logs.filter((l) => l.startsWith('ERROR')).join('|'));
press(1);
press(4);
await until('two runs', () => runs.length === 2);
console.log(runs.join());
press(0);
await until('the main page', () => drawn(0)?.startsWith('stat:overview'));
console.log(d.state().page, drawn(1), sampler.kinds.join());")"
assert_eq "system icon:back stat:top:1 true cpu,memory,swap,top,gpu,temperature,power,disk,network
true placeholder:disk ERROR couldn't draw the disk key: broken
activity-monitor,activity-monitor
main icon:editor overview" "$out" "page switching and stat keys"

# A press runs open-in once at a time for New Tab only, logs its output, and a failure alerts
out="$(daemon_js "decks = [deck()];
await d.start();
press(6); press(6); press(3); press(14);
await until('the alert', () => drawn(3) === ALERT);
await until('the alert to end', () => drawn(3) === 'icon:files');
console.log(runs.join(), logs.filter((l) => l.endsWith('ran')).join());
pending[0](null, '');
press(6);
console.log(runs.join());")"
assert_eq "chrome-tab,files files ran
chrome-tab,files,chrome-tab" "$out" "key presses"

# A failed write or error event drops the deck and stops sampling; it reconnects when it's back
out="$(daemon_js "const first = deck();
decks = [first];
await d.start();
await until('Overview stats', () => drawn(0)?.startsWith('stat:'));
decks = [];
first.fail = true;
await until('the disconnect', () => !d.state().connected);
const stops = sampler.stops;
console.log(first.log.join(), logs.find((l) => l.includes('disconnected')));
await new Promise((r) => setTimeout(r, 100));
console.log(sampler.stops === stops, opened.length);
const second = deck();
decks = [second];
await until('the reconnect', () => d.state().connected && drawn(1, second) === 'icon:editor');
second.emit('error', new Error('unplugged'));
await until('the second disconnect', () => !d.state().connected);
console.log(opened.length, logs.filter((l) => l.startsWith('Stream Deck')).join('|'));")"
assert_eq "close Stream Deck disconnected: write failed
true 1
2 Stream Deck connected: Stream Deck MK.2|Stream Deck disconnected: write failed|Stream Deck connected: Stream Deck MK.2|Stream Deck disconnected: unplugged" \
    "$out" "a deck that goes away and comes back"

# A deck of another size is logged once and left alone; stop leaves the deck on its logo
out="$(daemon_js "const xl = deck(8, 4);
decks = [xl];
await d.start();
await new Promise((r) => setTimeout(r, 100));
console.log(d.state().connected, opened.length, xl.log.join(), logs.join('|'));
decks = [xl, deck()];
await until('the 15-key deck', () => d.state().connected);
await d.stop();
console.log(opened.at(-1).log.join());")"
assert_eq "false 1 close The Stream Deck MK.2 has 8×4 keys; layout.json is for 5×3
logo,close" "$out" "another model, then stop"

# An action layout.json names that the manifest lacks is logged and left blank
out="$(node -e "const { createDaemon } = require(process.argv[1]);
const logs = [];
createDaemon({ layout: { columns: 5, rows: 3, links: { overview: 'main' }, pages: { main: { '0,0': 'nope', '1,0': 'overview', '2,0': 'cpu' } } },
  actions: new Set(['cpu']), keys: require(process.argv[2]), log: (m) => logs.push(m) });
console.log(logs.join());" "$DAEMON" "$PLUGIN_SRC/keys.js")"
assert_eq "ERROR layout.json's main page has nope at 0,0, which isn't an action" "$out" "an unknown action"

# Each key's icon: an SVG, a PNG wrapped in SVG, or blank
images="$SANDBOX/images"
mkdir -p "$images"
echo '<svg>cpu</svg>' > "$images/key-cpu.svg"
printf 'png' > "$images/key-editor@2x.png"
out="$(node -e "const { imageLoader, BLANK } = require(process.argv[1]);
const load = imageLoader(process.argv[2]);
console.log(load('cpu').trim(), load('editor').includes('href=\"data:image/png;base64,cG5n\"'), load('nope') === BLANK);" \
    "$DAEMON" "$images")"
assert_eq "<svg>cpu</svg> true true" "$out" "key icons"

# resvg gets the matched family's OpenType files only, not every system font; with no fontconfig,
# the system fonts
out="$(node -e "const { fontOptions } = require(process.argv[1]);
const calls = [];
const run = (file, args) => {
  calls.push(file + ' ' + args.join(' '));
  if (file === 'fc-match') return 'Nimbus Sans-Narrow';
  return ['/f/NimbusSans-Regular.otf', '/f/NimbusSans-Regular.t1', '/f/NimbusSans-Bold.otf', ''].join('\n');
};
console.log(JSON.stringify(fontOptions(run)));
console.log(calls.join('|'));
console.log(JSON.stringify(fontOptions(() => { throw new Error('ENOENT'); })));" "$DAEMON")"
assert_eq '{"loadSystemFonts":false,"fontFiles":["/f/NimbusSans-Bold.otf","/f/NimbusSans-Regular.otf"],"defaultFontFamily":"Nimbus Sans-Narrow","sansSerifFamily":"Nimbus Sans-Narrow"}
fc-match -f %{family[0]} Helvetica:charset=2191 2193 b0 b7 2026 2014|fc-list -f %{file}
 Nimbus Sans\-Narrow
{"loadSystemFonts":true,"defaultFontFamily":"DejaVu Sans","sansSerifFamily":"DejaVu Sans"}' "$out" "the fonts resvg loads"

# With the daemon's packages installed (pnpm install in stream-deck/linux) and fontconfig, the
# network and temperature keys' symbols render with those fonts
resvg="$REPO_DIR/stream-deck/linux/node_modules/@resvg/resvg-js"
if [ -d "$resvg" ] && command -v fc-match &> /dev/null; then
    out="$(node -e "const { Resvg } = require(process.argv[1]);
const { fontOptions } = require(process.argv[2]);
const font = fontOptions();
// Lit pixels of one glyph, white on black
const ink = (c) => {
  const svg = '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"144\" height=\"144\"><rect width=\"144\" height=\"144\"/>' +
    '<text x=\"72\" y=\"100\" font-family=\"Helvetica Neue, Helvetica, Arial, sans-serif\" font-size=\"80\" fill=\"#fff\">' + c + '</text></svg>';
  const px = new Resvg(svg, { font }).render().pixels;
  let lit = 0;
  for (let i = 0; i < px.length; i += 4) if (px[i] > 128) lit++;
  return lit;
};
console.log(font.loadSystemFonts, ['↑', '↓', '°', '·', '—'].filter((c) => ink(c) === 0).join(' ') || 'all drawn');" \
        "$resvg" "$DAEMON")"
    assert_eq "false all drawn" "$out" "the keys' symbols with the resolved fonts"
fi

test_done
