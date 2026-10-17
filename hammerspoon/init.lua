-- Global hotkeys. Each opens its app, or brings it to the front when it's running:
--   Ctrl+Opt+Space  Claude
--   Ctrl+Opt+B      Google Chrome
--   Ctrl+Opt+N      a new Chrome tab, with the clipboard's text pasted into the address bar and
--                   selected, so typing or Delete replaces it
--   Ctrl+Opt+T      Ghostty at the folder in front, as the Stream Deck's Terminal key does
--   Ctrl+Opt+C      T3 Code
--   Ctrl+Opt+E      Zed at the folder or file in front, as the Stream Deck's Editor key does
-- The hammerspoon step copies this file to ~/.hammerspoon/init.lua, and the Stream Deck plugin's
-- bin/open-in, which finds the folder or file, to ~/.hammerspoon/bin/open-in. Hammerspoon needs
-- Accessibility to send the new tab's keystrokes and read Zed's window title and T3 Code's page,
-- both manual steps, and macOS asks it for Automation of Ghostty, Finder, and System Events. The
-- Stream Deck plugin's bin/open-app does the same for its keys.

local CLAUDE = "com.anthropic.claudefordesktop"
local CHROME = "com.google.Chrome"
local T3_CODE = "com.t3tools.t3code"
local OPEN_IN = hs.configdir .. "/bin/open-in"
local MODS = { "ctrl", "alt" }
-- How long Chrome gets to come to the front, which includes starting it
local FRONT_TIMEOUT = 10
-- How long Chrome gets to focus the new tab's address bar before the paste
local NEW_TAB_DELAY = 0.15
-- Microseconds between each keystroke's key down and key up
local KEY_DELAY = 20000

-- Hammerspoon garbage-collects a timer or watcher nothing refers to, so they're kept here
dotfiles = {}

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

local function chromeInFront()
    local app = hs.application.get(CHROME)
    return app ~= nil and app:isFrontmost()
end

-- The hotkey's Ctrl+Opt, still held, would turn the Cmd+T sent below into Ctrl+Opt+Cmd+T
local function modifiersHeld()
    local mods = hs.eventtap.checkKeyboardModifiers()
    return mods.cmd or mods.alt or mods.ctrl or mods.shift
end

local function newChromeTab()
    if not open(CHROME, "Google Chrome") then
        return
    end
    local deadline = hs.timer.secondsSinceEpoch() + FRONT_TIMEOUT
    dotfiles.newTab = hs.timer.waitUntil(function()
        return (chromeInFront() and not modifiersHeld()) or hs.timer.secondsSinceEpoch() > deadline
    end, function()
        if not chromeInFront() then
            hs.alert.show("Google Chrome didn't come to the front")
            return
        end
        -- With no window open, Cmd+T opens one
        hs.eventtap.keyStroke({ "cmd" }, "t", KEY_DELAY)
        -- Whitespace alone isn't worth pasting
        local text = hs.pasteboard.readString()
        if text == nil or not text:match("%S") then
            return
        end
        dotfiles.paste = hs.timer.doAfter(NEW_TAB_DELAY, function()
            -- Another app came to the front in the meantime
            if not chromeInFront() then
                return
            end
            hs.eventtap.keyStroke({ "cmd" }, "v", KEY_DELAY)
            hs.eventtap.keyStroke({ "cmd" }, "a", KEY_DELAY)
        end)
    end, 0.02)
end

-- open-in shows a notification when it fails, so only its log line is left to print
local function openIn(target)
    local task = hs.task.new("/bin/bash", function(_, _, stderr)
        print("open-in: " .. stderr)
    end, { OPEN_IN, target })
    local env = task:environment()
    env.OPEN_IN_CALLER = "Hammerspoon"
    env.OPEN_IN_LOG = "Hammerspoon's console"
    task:setEnvironment(env)
    if not task:start() then
        hs.alert.show("Couldn't run " .. OPEN_IN)
        return
    end
    dotfiles.openIn = task
end

hs.hotkey.bind(MODS, "space", function() open(CLAUDE, "Claude") end)
hs.hotkey.bind(MODS, "b", function() open(CHROME, "Google Chrome") end)
hs.hotkey.bind(MODS, "n", newChromeTab)
hs.hotkey.bind(MODS, "t", function() openIn("terminal") end)
hs.hotkey.bind(MODS, "c", function() open(T3_CODE, "T3 Code") end)
hs.hotkey.bind(MODS, "e", function() openIn("editor") end)
