#!/bin/bash
set -euo pipefail

# hammerspoon/init.lua, run by lua against a fake hs that records what the config does: it binds
# Ctrl+Opt+Cmd+Space, B, and C, each opening its app, T and E, which run open-in terminal and editor
# as Hammerspoon, and N for a new Chrome tab, which activates a running Chrome rather than
# reopening it, waits for Chrome in front with the hotkey's modifiers released, presses Cmd+T, then
# pastes and selects only when the clipboard holds more than whitespace, and starts over on a
# second press. It keeps each open-in task until it exits, sets Hammerspoon to open at login, and
# reloads when init.lua changes.
# tests/test-config-steps.sh covers the step that copies it, and tests/test-stream-deck-open-in.sh
# covers open-in.

# shellcheck source=lib.sh
source "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_sandbox
LUA="$(command -v lua || command -v lua5.4 || true)"
[ -n "$LUA" ] || skip "lua isn't installed"

# The fake hs. Timers run when the test calls tick() or flush(), and each call it records goes
# into calls, which print_calls prints and clears.
cat > "$SANDBOX/fake-hs.lua" <<'EOF'
calls = {}
local function record(s) calls[#calls + 1] = s end
function print_calls()
    for _, s in ipairs(calls) do print(s) end
    calls = {}
end

state = { front = nil, mods = {}, clipboard = nil, now = 0, installed = { ["com.google.Chrome"] = true, ["com.anthropic.claudefordesktop"] = true, ["com.t3tools.t3code"] = true }, running = {}, taskStarts = true }
hotkeys, waiters, delayed, watchers = {}, {}, {}, {}

hs = {
    configdir = "/home/.hammerspoon",
    autoLaunch = function(on) record("autoLaunch " .. tostring(on)) end,
    reload = function() record("reload") end,
    alert = { show = function(s) record("alert " .. s) end },
    pasteboard = { readString = function() return state.clipboard end },
    task = { new = function(path, fn, args)
        local t = { env = { PATH = "/usr/bin" } }
        function t:environment() return self.env end
        function t:setEnvironment(env) self.env = env end
        function t:start()
            if not state.taskStarts then return false end
            record("task " .. path .. " " .. table.concat(args, " ") .. " as " .. self.env.OPEN_IN_CALLER
                .. ", logging to " .. self.env.OPEN_IN_LOG .. ", PATH " .. self.env.PATH)
            -- The task's exit runs the callback later
            delayed[#delayed + 1] = { fn = function() fn(0, "", args[2] .. " from com.apple.finder: /tmp") end }
            return self
        end
        return t
    end },
    pathwatcher = { new = function(path, fn)
        local w = { path = path, fn = fn }
        function w:start() watchers[#watchers + 1] = self; return self end
        return w
    end },
    hotkey = { bind = function(mods, key, fn) hotkeys[table.concat(mods, "+") .. "+" .. key] = fn end },
    application = {
        launchOrFocusByBundleID = function(id)
            record("open " .. id)
            if not state.installed[id] then return false end
            -- Comes to the front at the next tick, as a launch takes a while
            state.pending = id
            state.running[id] = true
            return true
        end,
        -- nil for an app that isn't running
        get = function(id)
            if not state.running[id] and id ~= state.front then return nil end
            return {
                isFrontmost = function() return id == state.front end,
                activate = function() record("activate " .. id); state.pending = id; return true end,
            }
        end,
    },
    eventtap = {
        checkKeyboardModifiers = function() return state.mods end,
        keyStroke = function(mods, key) record("key " .. table.concat(mods, "+") .. "+" .. key) end,
    },
    timer = {
        secondsSinceEpoch = function() return state.now end,
        waitUntil = function(pred, fn)
            local w = { pred = pred, fn = fn }
            function w:stop() self.stopped = true end
            waiters[#waiters + 1] = w
            return w
        end,
        doAfter = function(_, fn)
            local t = { fn = fn }
            function t:stop() self.stopped = true end
            delayed[#delayed + 1] = t
            return t
        end,
    },
}

-- Advance time by a second: a pending app comes to the front, then the waiters whose predicate
-- holds run
function tick()
    state.now = state.now + 1
    if state.pending then state.front, state.pending = state.pending, nil end
    local still = {}
    for _, w in ipairs(waiters) do
        if w.stopped then
        elseif w.pred() then w.fn() else still[#still + 1] = w end
    end
    waiters = still
end

-- Run the delayed functions that weren't stopped
function flush()
    local d = delayed
    delayed = {}
    for _, t in ipairs(d) do
        if not t.stopped then t.fn() end
    end
end

-- The number of open-in tasks the config keeps
function task_count()
    local n = 0
    for _ in pairs(dotfiles.tasks) do n = n + 1 end
    return n
end
EOF

# Run the fake hs, init.lua, and a Lua snippet, printing the calls recorded
run_lua() {
    printf 'dofile(arg[1]); dofile(arg[2]); print_calls()\n%s\nprint_calls()\n' "$1" > "$SANDBOX/run.lua"
    RUN_OUTPUT="$("$LUA" "$SANDBOX/run.lua" "$SANDBOX/fake-hs.lua" "$REPO_DIR/hammerspoon/init.lua" 2>&1)" ||
        fail "lua failed: $RUN_OUTPUT"
}

# Loading: open at login, and the six hotkeys
run_lua 'local keys = {}
for k in pairs(hotkeys) do keys[#keys + 1] = k .. " " .. type(hotkeys[k]) end
table.sort(keys); print(table.concat(keys, "\n"))'
assert_eq "autoLaunch true
ctrl+alt+cmd+b function
ctrl+alt+cmd+c function
ctrl+alt+cmd+e function
ctrl+alt+cmd+n function
ctrl+alt+cmd+space function
ctrl+alt+cmd+t function" "$RUN_OUTPUT" "loading"

# Claude, Chrome, and T3 Code open, and a missing app shows an alert
run_lua 'hotkeys["ctrl+alt+cmd+space"](); hotkeys["ctrl+alt+cmd+b"](); hotkeys["ctrl+alt+cmd+c"]()
state.installed["com.google.Chrome"] = nil; hotkeys["ctrl+alt+cmd+b"]()'
assert_eq "autoLaunch true
open com.anthropic.claudefordesktop
open com.google.Chrome
open com.t3tools.t3code
open com.google.Chrome
alert Couldn't open Google Chrome" "$RUN_OUTPUT" "Claude, Chrome, and T3 Code"

# The terminal and the editor run the copied open-in, keeping Hammerspoon's environment, and print
# its log line to the console. One that can't start shows an alert.
# Each task is kept until it exits, so a second press doesn't drop the first.
run_lua 'hotkeys["ctrl+alt+cmd+t"](); hotkeys["ctrl+alt+cmd+e"](); print_calls(); print("tasks " .. task_count()); flush()
print("tasks " .. task_count())
state.taskStarts = false; hotkeys["ctrl+alt+cmd+e"]()'
assert_eq "autoLaunch true
task /bin/bash /home/.hammerspoon/bin/open-in terminal as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
task /bin/bash /home/.hammerspoon/bin/open-in editor as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
tasks 2
open-in: terminal from com.apple.finder: /tmp
open-in: editor from com.apple.finder: /tmp
tasks 0
alert Couldn't run /home/.hammerspoon/bin/open-in" "$RUN_OUTPUT" "the terminal and the editor"

# A new tab with text on the clipboard: nothing is pressed while Chrome isn't in front or the
# hotkey's modifiers are still held, then Cmd+T, and after the delay Cmd+V and Cmd+A
run_lua 'state.clipboard = "https://example.com"; state.mods = { ctrl = true, alt = true, cmd = true }
hotkeys["ctrl+alt+cmd+n"](); print_calls(); print("--")
tick(); print_calls(); print("--")
state.mods = {}; tick(); print_calls(); print("--")
flush()'
assert_eq "autoLaunch true
open com.google.Chrome
--
--
key cmd+t
--
key cmd+v
key cmd+a" "$RUN_OUTPUT" "a new tab with the clipboard"

# An empty clipboard, or only whitespace: Cmd+T alone
run_lua 'state.clipboard = " \n\t"; hotkeys["ctrl+alt+cmd+n"](); tick(); flush()
state.clipboard = nil; hotkeys["ctrl+alt+cmd+n"](); tick(); flush()'
assert_eq "autoLaunch true
open com.google.Chrome
key cmd+t
activate com.google.Chrome
key cmd+t" "$RUN_OUTPUT" "a new tab with no text"

# Another app comes to the front before the paste: no paste
run_lua 'state.clipboard = "x"; hotkeys["ctrl+alt+cmd+n"](); tick(); state.front = "other"; flush()'
assert_eq "autoLaunch true
open com.google.Chrome
key cmd+t" "$RUN_OUTPUT" "a new tab, then another app in front"

# Chrome is running: it's activated, not opened, which with no window would open one, and Cmd+T a
# second tab
run_lua 'state.running["com.google.Chrome"] = true; hotkeys["ctrl+alt+cmd+n"](); tick()'
assert_eq "autoLaunch true
activate com.google.Chrome
key cmd+t" "$RUN_OUTPUT" "a new tab in a running Chrome"

# A second press before Chrome comes to the front, or before the paste: one new tab, one paste
run_lua 'state.clipboard = "x"; hotkeys["ctrl+alt+cmd+n"](); hotkeys["ctrl+alt+cmd+n"](); tick(); print_calls(); print("--")
hotkeys["ctrl+alt+cmd+n"](); tick(); flush()'
assert_eq "autoLaunch true
open com.google.Chrome
activate com.google.Chrome
key cmd+t
--
activate com.google.Chrome
key cmd+t
key cmd+v
key cmd+a" "$RUN_OUTPUT" "a second press"

# Chrome never comes to the front: the wait gives up with an alert, pressing nothing
run_lua 'hotkeys["ctrl+alt+cmd+n"](); state.pending = nil
for _ = 1, 11 do tick() end'
assert_eq "autoLaunch true
open com.google.Chrome
alert Google Chrome didn't come to the front" "$RUN_OUTPUT" "Chrome not in front"

# A change to init.lua reloads; one to another file doesn't
run_lua 'print(watchers[1].path)
watchers[1].fn({ "/home/.hammerspoon/Spoons/x.lua" }); print_calls(); print("--")
watchers[1].fn({ "/home/.hammerspoon/init.lua" })'
assert_eq "autoLaunch true
/home/.hammerspoon
--
reload" "$RUN_OUTPUT" "reloading"
test_done
