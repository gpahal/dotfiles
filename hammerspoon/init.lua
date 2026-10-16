-- Global hotkeys. Each opens its app, or brings it to the front when it's running:
--   Ctrl+Opt+Space  Claude
--   Ctrl+Opt+C      Google Chrome
--   Ctrl+Opt+T      a new Chrome tab, with the clipboard's text pasted into the address bar and
--                   selected, so typing or Delete replaces it
-- The hammerspoon step copies this file to ~/.hammerspoon/init.lua. Hammerspoon needs
-- Accessibility to send the new tab's keystrokes, a manual step. The Stream Deck plugin's
-- bin/open-app does the same for its keys.

local CLAUDE = "com.anthropic.claudefordesktop"
local CHROME = "com.google.Chrome"
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

hs.hotkey.bind(MODS, "space", function() open(CLAUDE, "Claude") end)
hs.hotkey.bind(MODS, "c", function() open(CHROME, "Google Chrome") end)
hs.hotkey.bind(MODS, "t", newChromeTab)
