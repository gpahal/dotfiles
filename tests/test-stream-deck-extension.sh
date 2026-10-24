#!/bin/bash

# The dotfiles GNOME extension's methods under node, with GNOME Shell's modules mocked: the apps
# ActivateApp allows, the keys SendKeys allows, and what FocusedWindow shares.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v node &> /dev/null || skip "node isn't installed"
EXTENSION="$REPO_DIR/stream-deck/linux/gnome-extension/dotfiles@gpahal.com/extension.js"
mocks="$SANDBOX/mocks"
mkdir -p "$mocks"
# As .mjs, so node loads it as the ES module GNOME Shell does
cp "$EXTENSION" "$SANDBOX/extension.mjs"

# The mocks read and record through globalThis.gnome
cat > "$mocks/Clutter.mjs" << 'EOF'
const keyboard = { notify_keyval: (time, keyval, state) => gnome.keys.push(`${keyval}:${state}`), run_dispose() {} };
export default {
    KEY_Control_L: "Control_L", KEY_t: "t", KEY_v: "v", KEY_a: "a",
    ModifierType: { CONTROL_MASK: 4, SHIFT_MASK: 1, MOD1_MASK: 8, SUPER_MASK: 1 << 26, MOD4_MASK: 64, HYPER_MASK: 1 << 27, META_MASK: 1 << 28 },
    KeyState: { PRESSED: "down", RELEASED: "up" },
    InputDeviceType: { KEYBOARD_DEVICE: 1 },
    get_default_backend: () => ({ get_default_seat: () => ({ create_virtual_device: () => keyboard }) }),
};
EOF
cat > "$mocks/Gio.mjs" << 'EOF'
export default {
    DBus: { session: {} },
    DBusExportedObject: { wrapJSObject: (iface, service) => { gnome.service = service; return { export() {}, unexport() {} }; } },
};
EOF
echo 'export default { get_monotonic_time: () => gnome.clock, Variant: class {} };' > "$mocks/GLib.mjs"
echo 'export default { TabList: { NORMAL_ALL: 0 } };' > "$mocks/Meta.mjs"
echo 'export default { AppSystem: { get_default: () => ({ lookup_app: (id) => gnome.apps[id] ?? null }) } };' > "$mocks/Shell.mjs"
echo 'export default { Clipboard: { get_default: () => ({}) }, ClipboardType: {} };' > "$mocks/St.mjs"
cat > "$mocks/main.mjs" << 'EOF'
export const sessionMode = { get isLocked() { return gnome.locked; } };
export const activateWindow = (window) => gnome.activated.push(window.get_title());
EOF
echo 'export class Extension {}' > "$mocks/extension.mjs"

# Runs $1 with the extension enabled: s is its D-Bus service, and win(class, title) makes a window
extension_js() {
    node --input-type=module -e 'import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";
const [extension, mocks] = process.argv.slice(1);
registerHooks({
  resolve(specifier, context, next) {
    const name = specifier.startsWith("gi://") ? specifier.slice(5) : specifier.startsWith("resource:///") ? specifier.split("/").pop().replace(".js", "") : null;
    return name ? { url: pathToFileURL(`${mocks}/${name}.mjs`).href, shortCircuit: true } : next(specifier, context);
  },
});
globalThis.gnome = { keys: [], activated: [], apps: {}, windows: [], focus: null, locked: false, mods: 0, clock: 0 };
globalThis.global = {
  display: {
    connect: (signal) => signal,
    disconnect() {},
    get_focus_window: () => gnome.focus,
    get_tab_list: () => gnome.windows,
    get_current_time_roundtrip: () => 1,
  },
  get_pointer: () => [0, 0, gnome.mods],
};
const win = (cls, title = cls) => ({ get_wm_class: () => cls, get_title: () => title, get_gtk_window_object_path: () => "/w" });
const { default: Extension } = await import(pathToFileURL(extension).href);
new Extension().enable();
const s = gnome.service;
'"$1"'' "$SANDBOX/extension.mjs" "$mocks"
}

# ActivateApp focuses an app open-in opens, and refuses any other, even one with a window or a
# desktop file
out="$(extension_js 'gnome.windows = [win("google-chrome", "Chrome"), win("com.mitchellh.ghostty", "Ghostty")];
gnome.apps["com.mitchellh.ghostty.desktop"] = { activate_full: () => gnome.activated.push("launched") };
console.log(s.ActivateApp("google-chrome.desktop", "google-chrome"), gnome.activated.join());
console.log(s.ActivateApp("com.mitchellh.ghostty.desktop", "com.mitchellh.ghostty"), s.ActivateApp("", ""),
    s.ActivateApp("constructor", "com.mitchellh.ghostty"), gnome.activated.join());')"
assert_eq "true Chrome
false false false Chrome" "$out" "apps ActivateApp focuses and refuses"

# SendKeys presses and releases New Tab's keys, only into Chrome and only while unlocked
out="$(extension_js 'gnome.focus = win("google-chrome");
console.log(s.SendKeys("ctrl+t"), gnome.keys.join(" "));
gnome.keys = [];
const refused = [s.SendKeys("ctrl+w"), s.SendKeys("super"), s.SendKeys("constructor"), s.SendKeys("")];
gnome.locked = true;
refused.push(s.SendKeys("ctrl+v"));
gnome.locked = false;
gnome.focus = win("com.mitchellh.ghostty");
refused.push(s.SendKeys("ctrl+a"));
gnome.focus = null;
refused.push(s.SendKeys("ctrl+a"));
console.log(refused.join(), gnome.keys.length);
gnome.mods = 4;
const held = s.ModifiersHeld();
gnome.mods = 16;
console.log(held, s.ModifiersHeld());')"
assert_eq "true Control_L:down t:down t:up Control_L:up
false,false,false,false,false,false,false 0
true false" "$out" "the keys SendKeys sends"

# FocusedWindow shares a title only where open-in reads a path from it, and nothing while locked
out="$(extension_js 'gnome.focus = win("com.mitchellh.ghostty", "~/notes");
console.log(s.FocusedWindow());
gnome.focus = win("google-chrome", "Bank – statement");
console.log(s.FocusedWindow());
gnome.locked = true;
console.log(s.FocusedWindow());
gnome.locked = false;
gnome.focus = null;
console.log(s.FocusedWindow());')"
assert_eq '{"wmClass":"com.mitchellh.ghostty","title":"~/notes","gtkObjectPath":"/w"}
{"wmClass":"google-chrome"}
{}
{}' "$out" "the focused window"

test_done
