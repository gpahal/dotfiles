// Gives stream-deck/linux/bin/open-in what Wayland keeps inside the shell: the focused window,
// focusing and launching apps, and typing keys. Exports com.gpahal.Dotfiles at /com/gpahal/Dotfiles
// on the session bus, under org.gnome.Shell, so any process in your session can call it, as any
// can already type through /dev/uinput here.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const OBJECT_PATH = '/com/gpahal/Dotfiles';
const IFACE = `<node>
  <interface name="com.gpahal.Dotfiles">
    <method name="FocusedWindow"><arg type="s" direction="out" name="json"/></method>
    <method name="ActivateApp">
      <arg type="s" direction="in" name="desktopId"/><arg type="s" direction="in" name="wmClass"/>
      <arg type="b" direction="out" name="found"/>
    </method>
    <method name="ExpectWindow">
      <arg type="s" direction="in" name="wmClass"/><arg type="u" direction="in" name="timeoutMs"/>
    </method>
    <method name="ModifiersHeld"><arg type="b" direction="out" name="held"/></method>
    <method name="SendKeys"><arg type="s" direction="in" name="keys"/><arg type="b" direction="out" name="sent"/></method>
    <method name="ClipboardHasText"><arg type="b" direction="out" name="hasText"/></method>
    <method name="IsLocked"><arg type="b" direction="out" name="locked"/></method>
  </interface>
</node>`;

// How long after ActivateApp launches an app its window may ask for focus and still get it
const LAUNCH_FOCUS_MS = 10000;

// A D-Bus call has no input event of its own, so the shell's current time is the last event's,
// older than your last keypress or click. Mutter refuses to focus a window for an older time,
// marks it as wanting attention instead, and GNOME shows "… is ready".
const now = () => global.display.get_current_time_roundtrip();

const MODIFIER_KEYS = {
    ctrl: Clutter.KEY_Control_L,
    shift: Clutter.KEY_Shift_L,
    alt: Clutter.KEY_Alt_L,
    super: Clutter.KEY_Super_L,
};
const MODIFIER_MASK = Clutter.ModifierType.CONTROL_MASK | Clutter.ModifierType.SHIFT_MASK |
    Clutter.ModifierType.MOD1_MASK | Clutter.ModifierType.SUPER_MASK | Clutter.ModifierType.MOD4_MASK |
    Clutter.ModifierType.HYPER_MASK | Clutter.ModifierType.META_MASK;

class Dotfiles {
    constructor() {
        this._expected = null;
        this._keyboard = Clutter.get_default_backend().get_default_seat()
            .create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        // Mutter refuses focus to a window that a process outside the shell opens or raises, and
        // marks it as wanting attention instead. ExpectWindow says which window to focus anyway.
        this._signals = [
            global.display.connect('window-created', (_display, window) => this._onCreated(window)),
            global.display.connect('window-demands-attention', (_display, window) => this._maybeFocus(window)),
            global.display.connect('window-marked-urgent', (_display, window) => this._maybeFocus(window)),
        ];
    }

    destroy() {
        for (const id of this._signals)
            global.display.disconnect(id);
        this._keyboard.run_dispose();
    }

    // A new window has no wm_class until it's mapped
    _onCreated(window) {
        const actor = window.get_compositor_private();
        if (!actor) {
            this._maybeFocus(window);
            return;
        }
        const id = actor.connect('first-frame', () => {
            actor.disconnect(id);
            this._maybeFocus(window);
        });
    }

    _maybeFocus(window) {
        const expected = this._expected;
        if (!expected || GLib.get_monotonic_time() > expected.until) {
            this._expected = null;
            return;
        }
        if (window.get_wm_class() !== expected.wmClass)
            return;
        this._expected = null;
        Main.activateWindow(window, now());
    }

    FocusedWindow() {
        const window = global.display.get_focus_window();
        if (!window)
            return '{}';
        const app = Shell.WindowTracker.get_default().get_window_app(window);
        return JSON.stringify({
            wmClass: window.get_wm_class() ?? '',
            appId: app?.get_id() ?? '',
            title: window.get_title() ?? '',
            gtkObjectPath: window.get_gtk_window_object_path() ?? '',
        });
    }

    // Focuses the most recently used window of the class, else launches the app. By class, since
    // an app can register another desktop file at run time, as T3 Code does, and own its windows.
    ActivateApp(desktopId, wmClass) {
        const window = global.display.get_tab_list(Meta.TabList.NORMAL_ALL, null)
            .find(w => w.get_wm_class() === wmClass);
        if (window) {
            Main.activateWindow(window, now());
            return true;
        }
        const app = Shell.AppSystem.get_default().lookup_app(desktopId);
        if (!app)
            return false;
        // A running app asked to open again may hand off to its window, which then asks for focus
        this.ExpectWindow(wmClass, LAUNCH_FOCUS_MS);
        app.activate_full(-1, now());
        return true;
    }

    ExpectWindow(wmClass, timeoutMs) {
        this._expected = {wmClass, until: GLib.get_monotonic_time() + timeoutMs * 1000};
    }

    ModifiersHeld() {
        const [, , mods] = global.get_pointer();
        return (mods & MODIFIER_MASK) !== 0;
    }

    // One combination, such as "ctrl+t": presses each key in order, then releases them in reverse
    SendKeys(keys) {
        const keyvals = keys.split('+').map(name => MODIFIER_KEYS[name] ?? Clutter[`KEY_${name}`]);
        if (keyvals.length === 0 || keyvals.some(keyval => keyval === undefined))
            return false;
        let time = GLib.get_monotonic_time();
        for (const keyval of keyvals)
            this._keyboard.notify_keyval(time++, keyval, Clutter.KeyState.PRESSED);
        for (const keyval of keyvals.reverse())
            this._keyboard.notify_keyval(time++, keyval, Clutter.KeyState.RELEASED);
        return true;
    }

    // The shell reads the clipboard itself, so no popup takes focus as wl-paste's does
    ClipboardHasTextAsync(_params, invocation) {
        St.Clipboard.get_default().get_text(St.ClipboardType.CLIPBOARD, (_clipboard, text) => {
            invocation.return_value(new GLib.Variant('(b)', [Boolean(text && /\S/.test(text))]));
        });
    }

    IsLocked() {
        return Main.sessionMode.isLocked;
    }
}

export default class DotfilesExtension extends Extension {
    enable() {
        this._service = new Dotfiles();
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this._service);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
    }

    disable() {
        this._dbus.unexport();
        this._dbus = null;
        this._service.destroy();
        this._service = null;
    }
}
