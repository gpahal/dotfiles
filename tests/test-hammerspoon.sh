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

state = { installed = { ["com.google.Chrome"] = true, ["com.anthropic.claudefordesktop"] = true, ["com.t3tools.t3code"] = true }, taskStarts = true, exitCode = 0 }
hotkeys, delayed, watchers = {}, {}, {}

hs = {
    configdir = "/home/.hammerspoon",
    autoLaunch = function(on) record("autoLaunch " .. tostring(on)) end,
    reload = function() record("reload") end,
    alert = { show = function(s) record("alert " .. s) end },
    task = { new = function(path, fn, args)
        local t = { env = { PATH = "/usr/bin" } }
        function t:isRunning() return self.running == true end
        function t:environment() return self.env end
        function t:setEnvironment(env) self.env = env end
        function t:start()
            if not state.taskStarts then return false end
            record("task " .. path .. " " .. table.concat(args, " ") .. " as " .. self.env.OPEN_IN_CALLER
                .. ", logging to " .. self.env.OPEN_IN_LOG .. ", PATH " .. self.env.PATH)
            -- The task's exit runs the callback later
            self.running = true
            delayed[#delayed + 1] = { fn = function() self.running = false; fn(state.exitCode, "", args[2] .. " from com.apple.finder: /tmp") end }
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
            return state.installed[id] == true
        end,
    },
}

-- Run the task exits
function flush()
    local d = delayed
    delayed = {}
    for _, t in ipairs(d) do t.fn() end
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

run_lua 'hotkeys["ctrl+alt+cmd+space"](); hotkeys["ctrl+alt+cmd+b"](); hotkeys["ctrl+alt+cmd+c"]()
state.installed["com.google.Chrome"] = nil; hotkeys["ctrl+alt+cmd+b"]()'
assert_eq "autoLaunch true
open com.anthropic.claudefordesktop
open com.google.Chrome
open com.t3tools.t3code
open com.google.Chrome
alert Couldn't open Google Chrome" "$RUN_OUTPUT" "Claude, Chrome, and T3 Code"

# Each task is kept until it exits, so a second press doesn't drop the first
run_lua 'hotkeys["ctrl+alt+cmd+t"](); hotkeys["ctrl+alt+cmd+e"](); hotkeys["ctrl+alt+cmd+n"]()
print_calls(); print("tasks " .. task_count()); flush()
print("tasks " .. task_count())
state.taskStarts = false; hotkeys["ctrl+alt+cmd+e"]()'
assert_eq "autoLaunch true
task /bin/bash /home/.hammerspoon/bin/open-in terminal as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
task /bin/bash /home/.hammerspoon/bin/open-in editor as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
task /bin/bash /home/.hammerspoon/bin/open-in chrome-tab as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
tasks 3
open-in: terminal from com.apple.finder: /tmp
open-in: editor from com.apple.finder: /tmp
open-in: chrome-tab from com.apple.finder: /tmp
tasks 0
alert Couldn't run /home/.hammerspoon/bin/open-in" "$RUN_OUTPUT" "the terminal, the editor, and the new tab"

# A second new-tab press while the first runs is dropped, so there's one tab and one paste
run_lua 'hotkeys["ctrl+alt+cmd+n"](); hotkeys["ctrl+alt+cmd+n"](); print_calls(); print("--"); flush()
print_calls(); print("--"); hotkeys["ctrl+alt+cmd+n"]()'
assert_eq "autoLaunch true
task /bin/bash /home/.hammerspoon/bin/open-in chrome-tab as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
--
open-in: chrome-tab from com.apple.finder: /tmp
--
task /bin/bash /home/.hammerspoon/bin/open-in chrome-tab as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin" "$RUN_OUTPUT" "a second press"

# Exit 127 or 126 alerts, since open-in can't notify; other failures are open-in's to report
run_lua 'for _, code in ipairs({ 127, 126, 1 }) do
    state.exitCode = code; hotkeys["ctrl+alt+cmd+t"](); print_calls(); flush()
end'
assert_eq "autoLaunch true
task /bin/bash /home/.hammerspoon/bin/open-in terminal as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
open-in: terminal from com.apple.finder: /tmp
alert Couldn't run /home/.hammerspoon/bin/open-in; re-run the hammerspoon step
task /bin/bash /home/.hammerspoon/bin/open-in terminal as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
open-in: terminal from com.apple.finder: /tmp
alert Couldn't run /home/.hammerspoon/bin/open-in; re-run the hammerspoon step
task /bin/bash /home/.hammerspoon/bin/open-in terminal as Hammerspoon, logging to Hammerspoon's console, PATH /usr/bin
open-in: terminal from com.apple.finder: /tmp" "$RUN_OUTPUT" "open-in missing or not runnable"

run_lua 'print(watchers[1].path)
watchers[1].fn({ "/home/.hammerspoon/Spoons/x.lua" }); print_calls(); print("--")
watchers[1].fn({ "/home/.hammerspoon/init.lua" })'
assert_eq "autoLaunch true
/home/.hammerspoon
--
reload" "$RUN_OUTPUT" "reloading"
test_done
