#!/bin/bash
set -euo pipefail

# hammerspoon/init.lua under lua with a fake hs that records each call.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
LUA="$(command -v lua || command -v lua5.4 || true)"
[ -n "$LUA" ] || skip "lua isn't installed"

# A task's exit runs only when the test calls flush()
cat > "$SANDBOX/fake-hs.lua" <<'EOF'
calls = {}
local function record(s) calls[#calls + 1] = s end
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
    alert = { show = function(s) record("alert " .. s) end },
    task = { new = function(path, fn, args)
        local t = { env = {} }
        function t:isRunning() return self.running == true end
        function t:environment() return self.env end
        function t:setEnvironment(env) self.env = env end
        function t:start()
            if not state.taskStarts then return false end
            -- task_count() counts open-in's tasks
            if not self.env.OPEN_IN_CALLER then record("task " .. path .. " " .. table.concat(args, " ")) end
            self.running = true
            delayed[#delayed + 1] = function() self.running = false; fn(0, "", args[2] .. " from com.apple.finder: /tmp") end
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
}

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

-- The number of open-in tasks the config keeps
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
print("tasks " .. task_count()); flush()
print("tasks " .. task_count())
state.taskStarts = false; hotkeys["ctrl+alt+cmd+e"]()'
assert_eq "autoLaunch true
tasks 3
open-in: terminal from com.apple.finder: /tmp
open-in: editor from com.apple.finder: /tmp
open-in: chrome-tab from com.apple.finder: /tmp
tasks 0
alert Couldn't run /home/.hammerspoon/bin/open-in" "$RUN_OUTPUT" "the terminal, the editor, and the new tab"

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
device=19f5:2620
input=27
m1ddc=/opt/homebrew/bin/m1ddc"
DONGLE='{ vendorID = 0x19f5, productID = 0x2620, productName = "Air75 V3 Dongle" }'
MOUSE='{ vendorID = 0x046d, productID = 0xc548 }'

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
test_done
