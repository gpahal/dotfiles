#!/bin/bash

# hammerspoon/init.lua under lua with a fake hs that records each call.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LUA="$(command -v lua || command -v lua5.4 || true)"
[ -n "$LUA" ] || skip "lua isn't installed"

# A task's exit runs only when the test calls flush()
cat > "$SANDBOX/fake-hs.lua" <<'EOF'
calls = {}
function record(s) calls[#calls + 1] = s end
function print_calls()
    for _, s in ipairs(calls) do print(s) end
    calls = {}
end

state = { taskStarts = true }
hotkeys, delayed, timers, usb = {}, {}, {}, { attached = {} }
-- A watcher whose start() runs fn
local function watcher(fn) return { start = function(self) fn(); return self end } end

hs = {
    configdir = os.getenv("HS_CONFIGDIR") or "/home/.hammerspoon",
    autoLaunch = function(on) record("autoLaunch " .. tostring(on)) end,
    alert = {
        show = function(s) record("alert " .. s); return s end,
        closeSpecific = function() end,
    },
    task = { new = function(path, fn, args)
        local t = { env = {} }
        function t:isRunning() return self.running == true end
        function t:environment() return self.env end
        function t:setEnvironment(env) self.env = env end
        function t:start()
            if not state.taskStarts then return false end
            -- task_count() counts open-in's tasks, so they aren't recorded
            if not self.env.OPEN_IN_CALLER then record("task " .. path .. " " .. table.concat(args, " ")) end
            self.running = true
            delayed[#delayed + 1] = function()
                self.running = false
                if path:match("/m1ddc$") then return fn(fake_m1ddc(args)) end
                fn(0, "", args[2] .. " from com.apple.finder: /tmp")
            end
            return self
        end
        return t
    end },
    pathwatcher = { new = function() return watcher(function() end) end },
    usb = {
        attachedDevices = function() return usb.attached end,
        watcher = { new = function(fn) return watcher(function() usb.watcher = fn end) end },
    },
    timer = { doAfter = function(delay, fn)
        local t = { delay = delay, fn = fn }
        function t:stop() self.stopped = true end
        timers[#timers + 1] = t
        return t
    end },
    caffeinate = { watcher = {
        systemDidWake = "didWake",
        new = function(fn) return watcher(function() usb.wake = fn end) end,
    } },
    hotkey = { bind = function(mods, key, fn) hotkeys[table.concat(mods, "+") .. "+" .. key] = fn end },
    fs = { attributes = function(path) if not (path:match("/m1ddc$") and state.noM1ddc) then return {} end end },
    audiodevice = { defaultOutputDevice = function()
        return {
            transportType = function() return output.transport end,
            outputVolume = function() return output.volume end,
        }
    end },
    settings = {
        get = function(k) return settings[k] end,
        set = function(k, v) settings[k] = v end,
        clear = function(k) settings[k] = nil end,
    },
    eventtap = {
        event = { types = { systemDefined = 14 } },
        new = function(_, fn) volumeTap = fn; return { start = function(self) return self end } end,
    },
}

-- The default output: a display over DisplayPort, which macOS can't set the volume of
output = { transport = "DisplayPort" }
settings = {}

-- m1ddc's volume commands on a monitor at state.level, or failing with state.m1ddcFails. Reads
-- answer state.junk's values first, as some monitors answer reads with junk.
state.level, state.junk = 40, {}
function fake_m1ddc(args)
    if state.m1ddcFails then return 1, "", "No external display" end
    if args[1] == "get" then
        return 0, (table.remove(state.junk, 1) or state.level) .. "\n", ""
    end
    state.level = tonumber(args[3])
    return 0, state.level .. "\n", ""
end

-- Presses a system key, recording it, then what it started, then whether the config swallowed its
-- down and up
function press(key, flags, rep)
    local swallowed = {}
    record(key)
    for _, down in ipairs({ true, false }) do
        swallowed[#swallowed + 1] = tostring(volumeTap({
            systemKey = function() return { key = key, down = down, ["repeat"] = rep } end,
            getFlags = function() return flags or {} end,
        }))
    end
    record("  swallowed " .. table.concat(swallowed, " "))
end

-- Run the task exits
function flush()
    local d = delayed
    delayed = {}
    for _, fn in ipairs(d) do fn() end
end

-- Fire the timers still pending, printing each one's delay
function fire()
    local t = timers
    timers = {}
    for _, timer in ipairs(t) do
        if not timer.stopped then print("after " .. timer.delay); timer.fn() end
    end
end

-- The number of tasks the config keeps
function task_count()
    local n = 0
    for _ in pairs(dotfiles.tasks) do n = n + 1 end
    return n
end
EOF

run_lua() {
    printf 'dofile(arg[1]); dofile(arg[2]); print_calls()\n%s\nprint_calls()\n' "$1" > "$SANDBOX/run.lua"
    RUN_OUTPUT="$("$LUA" "$SANDBOX/run.lua" "$SANDBOX/fake-hs.lua" "$REPO_DIR/hammerspoon/init.lua" 2>&1)" ||
        fail "lua failed: $RUN_OUTPUT"
}

# Each task is kept until it exits, so a second press doesn't drop the first
run_lua 'hotkeys["ctrl+alt+cmd+t"](); hotkeys["ctrl+alt+cmd+e"](); hotkeys["ctrl+alt+cmd+n"]()
hotkeys["ctrl+alt+cmd+a"](); hotkeys["ctrl+alt+cmd+m"]()
print("tasks " .. task_count()); flush()
print("tasks " .. task_count())
state.taskStarts = false; hotkeys["ctrl+alt+cmd+e"]()'
assert_eq "autoLaunch true
tasks 5
open-in: terminal from com.apple.finder: /tmp
open-in: editor from com.apple.finder: /tmp
open-in: chrome-tab from com.apple.finder: /tmp
open-in: agenda from com.apple.finder: /tmp
open-in: gmail from com.apple.finder: /tmp
tasks 0
alert Couldn't run /home/.hammerspoon/bin/open-in" "$RUN_OUTPUT" "the terminal, the editor, the new tab, the agenda, and Gmail"

# A second new-tab press while the first runs is dropped, so there's one tab and one paste
run_lua 'hotkeys["ctrl+alt+cmd+n"](); hotkeys["ctrl+alt+cmd+n"](); print("tasks " .. task_count()); flush()
hotkeys["ctrl+alt+cmd+n"](); print("tasks " .. task_count())'
assert_eq "autoLaunch true
tasks 1
open-in: chrome-tab from com.apple.finder: /tmp
tasks 1" "$RUN_OUTPUT" "a second press"

# Usage: run_monitor <monitor-input.conf> <lua>
run_monitor() {
    mkdir -p "$SANDBOX/hs"
    printf '%s\n' "$1" > "$SANDBOX/hs/monitor-input.conf"
    HS_CONFIGDIR="$SANDBOX/hs" run_lua "$2"
}

CONF="# From just monitor-input
device=1234:5678
input=27
m1ddc=/opt/homebrew/bin/m1ddc"
DONGLE='{ vendorID = 0x1234, productID = 0x5678, productName = "Keyboard Receiver" }'
MOUSE='{ vendorID = 0x0abc, productID = 0xef01 }'

# A burst of events switches once, after the last; a device that isn't the trigger does nothing
run_monitor "$CONF" "usb.attached = { $MOUSE, $DONGLE }
usb.watcher($MOUSE); fire(); print('--')
usb.watcher($DONGLE); usb.watcher($MOUSE); usb.watcher($DONGLE); fire(); print_calls(); flush()
print('tasks ' .. task_count())"
assert_eq "autoLaunch true
--
after 1
task /opt/homebrew/bin/m1ddc set input 27
tasks 0" "$RUN_OUTPUT" "switching to the Mac when the device arrives"

# It never switches away, so it can't undo the Ubuntu machine's switch
run_monitor "$CONF" "usb.attached = { $MOUSE }
usb.watcher($DONGLE); fire(); usb.wake('didWake'); fire(); usb.wake('willSleep'); fire()"
assert_eq "autoLaunch true
after 1
after 3" "$RUN_OUTPUT" "the device leaving, and a wake without it"
# The volume keys while the monitor is the output: presses while m1ddc runs add up into one change,
# from a level read at the start of the run of presses and read again at the next
run_lua 'press("SOUND_UP"); press("SOUND_UP"); flush(); press("SOUND_UP"); flush(); flush(); flush()
press("SOUND_DOWN", { shift = true, alt = true }); flush(); flush(); flush()
record("level " .. state.level .. ", tasks " .. task_count())'
assert_eq "autoLaunch true
SOUND_UP
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
SOUND_UP
  swallowed true true
task /opt/homebrew/bin/m1ddc get volume
SOUND_UP
  swallowed true true
task /opt/homebrew/bin/m1ddc set volume 58
alert Monitor volume 58
SOUND_DOWN
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc set volume 57
alert Monitor volume 57
level 57, tasks 0" "$RUN_OUTPUT" "volume up and down on the monitor"

# Junk reads, and reads that never agree twice in a row, don't set the volume
run_lua 'state.junk = { 110, 128, 128 }; press("SOUND_DOWN"); for _ = 1, 6 do flush() end
record("level " .. state.level)
state.junk = { 110, 40, 128, 110, 40, 128, 110, 40 }; press("SOUND_DOWN"); for _ = 1, 9 do flush() end
record("level " .. state.level .. ", tasks " .. task_count())'
assert_eq "autoLaunch true
SOUND_DOWN
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc set volume 34
alert Monitor volume 34
level 34
SOUND_DOWN
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc get volume
alert Couldn't read the monitor's volume
level 34, tasks 0" "$RUN_OUTPUT" "junk reads of the monitor's volume"

# Mute keeps the volume for unmute; a held mute key's repeats don't toggle it back; down while
# muted stays muted, and up unmutes
run_lua 'press("MUTE"); press("MUTE", nil, true); flush(); flush(); flush()
record("level " .. state.level .. ", kept " .. settings["dotfiles.monitorMutedVolume"])
press("SOUND_DOWN"); press("MUTE"); flush(); record("level " .. state.level)
press("MUTE"); flush(); flush(); flush(); press("SOUND_UP"); flush()
record("level " .. state.level .. ", kept " .. tostring(settings["dotfiles.monitorMutedVolume"]))'
assert_eq "autoLaunch true
MUTE
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
MUTE
  swallowed true true
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc set volume 0
alert Monitor volume muted
level 0, kept 40
SOUND_DOWN
alert Monitor volume muted
  swallowed true true
MUTE
task /opt/homebrew/bin/m1ddc set volume 40
  swallowed true true
alert Monitor volume 40
level 40
MUTE
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc set volume 0
alert Monitor volume muted
SOUND_UP
task /opt/homebrew/bin/m1ddc set volume 46
  swallowed true true
alert Monitor volume 46
level 46, kept nil" "$RUN_OUTPUT" "mute and unmute on the monitor"

# A failed m1ddc drops what's pending, so the next press starts afresh
run_lua 'state.m1ddcFails = true; press("SOUND_UP"); press("SOUND_UP"); print_calls(); flush()
state.m1ddcFails = false; press("SOUND_UP"); flush(); flush(); flush()'
assert_eq "autoLaunch true
SOUND_UP
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
SOUND_UP
  swallowed true true
m1ddc: No external display
alert Couldn't set the monitor's volume; see Hammerspoon's console
SOUND_UP
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
task /opt/homebrew/bin/m1ddc get volume
task /opt/homebrew/bin/m1ddc set volume 46
alert Monitor volume 46" "$RUN_OUTPUT" "a failed m1ddc"

# macOS keeps the keys for an output it can set, for HDMI it can set, without m1ddc, and for other
# system keys
run_lua 'output = { transport = "USB", volume = 50 }; press("SOUND_UP"); press("MUTE")
output = { transport = "HDMI", volume = 50 }; press("SOUND_UP")
output = { transport = "HDMI" }; state.noM1ddc = true; press("SOUND_UP")
state.noM1ddc = false; press("PLAY"); press("SOUND_DOWN"); record("tasks " .. task_count())'
assert_eq "autoLaunch true
SOUND_UP
  swallowed false false
MUTE
  swallowed false false
SOUND_UP
  swallowed false false
SOUND_UP
  swallowed false false
PLAY
  swallowed false false
SOUND_DOWN
task /opt/homebrew/bin/m1ddc get volume
  swallowed true true
tasks 1" "$RUN_OUTPUT" "outputs macOS can set, and other keys"
test_done
