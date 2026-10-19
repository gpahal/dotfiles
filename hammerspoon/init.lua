-- Needs Accessibility (a manual step) and Automation of Ghostty, Finder, System Events, and Chrome.

local CLAUDE = "com.anthropic.claudefordesktop"
local CHROME = "com.google.Chrome"
local T3_CODE = "com.t3tools.t3code"
local OPEN_IN = hs.configdir .. "/bin/open-in"
-- Ctrl+Opt alone clashes with Rectangle's shortcuts
local MODS = { "ctrl", "alt", "cmd" }

-- Hammerspoon garbage-collects a watcher or task nothing refers to
dotfiles = { tasks = {} }

hs.autoLaunch(true)

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

-- open-in notifies on its own failures, but not when bash can't run it (126, 127)
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

-- A second press while Chrome starts would open a second tab and paste twice
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
