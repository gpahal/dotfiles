-- Global hotkeys. Each opens its app, or brings it to the front when it's running:
--   Ctrl+Opt+Cmd+Space  Claude
--   Ctrl+Opt+Cmd+B      Google Chrome
--   Ctrl+Opt+Cmd+N      a new Chrome tab, with the clipboard's text pasted into the address bar
--                       and selected, so typing or Delete replaces it, as the Stream Deck's New
--                       Tab key does
--   Ctrl+Opt+Cmd+T      Ghostty at the folder in front, as the Stream Deck's Terminal key does
--   Ctrl+Opt+Cmd+C      T3 Code
--   Ctrl+Opt+Cmd+E      Zed at the folder or file in front, as the Stream Deck's Editor key does
-- Ctrl+Opt alone would clash with Rectangle's recommended shortcuts (Ctrl+Opt+C, E, and T), which
-- Rectangle uses with Cmd only on the arrow keys.
-- The hammerspoon step copies this file to ~/.hammerspoon/init.lua, and the Stream Deck plugin's
-- bin/open-in, which finds the folder or file and opens the new tab, to ~/.hammerspoon/bin/open-in.
-- Hammerspoon needs Accessibility, a manual step, to send the new tab's keystrokes and read Zed's
-- window title and T3 Code's page, and macOS asks it for Automation of Ghostty, Finder, System
-- Events, and Google Chrome.

local CLAUDE = "com.anthropic.claudefordesktop"
local CHROME = "com.google.Chrome"
local T3_CODE = "com.t3tools.t3code"
local OPEN_IN = hs.configdir .. "/bin/open-in"
local MODS = { "ctrl", "alt", "cmd" }

-- Hammerspoon garbage-collects a timer, watcher, or task nothing refers to, so they're kept here.
-- tasks holds each open-in still running, so a second press can't drop the first.
dotfiles = { tasks = {} }

-- Open Hammerspoon at login, so the hotkeys work from the start
hs.autoLaunch(true)

-- Reload when the hammerspoon step replaces this file
dotfiles.watcher = hs.pathwatcher.new(hs.configdir, function(paths)
    for _, path in ipairs(paths) do
        if path:match("/init%.lua$") then
            hs.reload()
            return
        end
    end
end):start()

local function open(bundleID, name)
    if hs.application.launchOrFocusByBundleID(bundleID) then
        return true
    end
    hs.alert.show("Couldn't open " .. name)
    return false
end

-- open-in shows a notification when it fails, so only its log line is left to print. bash exits
-- 127 when open-in is missing and 126 when it can't run it, and then no notification shows, so
-- those get an alert. Returns the task, or nil when it couldn't start.
local function openIn(target)
    local task
    task = hs.task.new("/bin/bash", function(exitCode, _, stderr)
        dotfiles.tasks[task] = nil
        print("open-in: " .. stderr)
        if exitCode == 126 or exitCode == 127 then
            hs.alert.show("Couldn't run " .. OPEN_IN .. "; re-run the hammerspoon step")
        end
    end, { OPEN_IN, target })
    local env = task:environment()
    env.OPEN_IN_CALLER = "Hammerspoon"
    env.OPEN_IN_LOG = "Hammerspoon's console"
    task:setEnvironment(env)
    if not task:start() then
        hs.alert.show("Couldn't run " .. OPEN_IN)
        return
    end
    dotfiles.tasks[task] = true
    return task
end

-- A second press while the first's tab is still on its way, as while Chrome starts, would open a
-- second tab and paste twice, so it's dropped
local function newTab()
    if dotfiles.newTab and dotfiles.newTab:isRunning() then
        return
    end
    dotfiles.newTab = openIn("chrome-tab")
end

hs.hotkey.bind(MODS, "space", function() open(CLAUDE, "Claude") end)
hs.hotkey.bind(MODS, "b", function() open(CHROME, "Google Chrome") end)
hs.hotkey.bind(MODS, "n", newTab)
hs.hotkey.bind(MODS, "t", function() openIn("terminal") end)
hs.hotkey.bind(MODS, "c", function() open(T3_CODE, "T3 Code") end)
hs.hotkey.bind(MODS, "e", function() openIn("editor") end)
