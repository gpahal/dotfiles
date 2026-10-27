-- Needs Accessibility (a manual step) and Automation of Ghostty, Finder, System Events, and Chrome.
-- With monitor-input.conf (just monitor-input), the monitor follows the USB switch to this Mac.
-- With m1ddc, the volume keys set the monitor's volume while it's the sound output.

local CLAUDE = "com.anthropic.claudefordesktop"
local CHROME = "com.google.Chrome"
local T3_CODE = "com.t3tools.t3code"
local OPEN_IN = hs.configdir .. "/bin/open-in"
local MONITOR_CONF = hs.configdir .. "/monitor-input.conf"
-- Ctrl+Opt alone clashes with Rectangle's shortcuts
local MODS = { "ctrl", "alt", "cmd" }

-- Hammerspoon garbage-collects a watcher or task nothing refers to
dotfiles = { tasks = {} }

hs.autoLaunch(true)

dotfiles.watcher = hs.pathwatcher.new(hs.configdir, function(paths)
    for _, path in ipairs(paths) do
        if path:match("/init%.lua$") or path:match("/monitor%-input%.conf$") then
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

-- Switches the monitor to this Mac once the switch's devices settle here, and after a wake that
-- finds them here. It never switches away: the Ubuntu machine hands the monitor back, so the two
-- can't undo each other when the devices leave both.
local SETTLE, WAKE_SETTLE = 1, 3

local function readConf(path)
    local file = io.open(path)
    if not file then return nil end
    local conf = {}
    for line in file:lines() do
        local key, value = line:match("^(%w+)=(.*)$")
        if key then conf[key] = value end
    end
    file:close()
    return conf
end

local function followMonitor()
    local conf = readConf(MONITOR_CONF)
    if not conf then return end
    local vendor, product = (conf.device or ""):match("^(%x%x%x%x):(%x%x%x%x)$")
    local input = (conf.input or ""):match("^%d+$")
    if not vendor or not input or (conf.m1ddc or "") == "" then
        hs.alert.show("Ignoring " .. MONITOR_CONF .. "; re-run just monitor-input")
        return
    end
    vendor, product = tonumber(vendor, 16), tonumber(product, 16)
    local function isTrigger(device)
        return device.vendorID == vendor and device.productID == product
    end
    local function attached()
        for _, device in ipairs(hs.usb.attachedDevices() or {}) do
            if isTrigger(device) then return true end
        end
        return false
    end
    local function switch()
        if not attached() then return end
        local task
        task = hs.task.new(conf.m1ddc, function(exitCode, _, stderr)
            dotfiles.tasks[task] = nil
            if exitCode ~= 0 then
                print("m1ddc: " .. stderr)
                hs.alert.show("Couldn't switch the monitor to this Mac; see Hammerspoon's console")
            end
        end, { "set", "input", input })
        if not (task and task:start()) then
            hs.alert.show("Couldn't run " .. conf.m1ddc .. "; re-run the homebrew step")
            return
        end
        dotfiles.tasks[task] = true
    end
    -- Each event restarts the wait, so a burst switches once
    local function later(delay)
        if dotfiles.monitorTimer then dotfiles.monitorTimer:stop() end
        dotfiles.monitorTimer = hs.timer.doAfter(delay, switch)
    end
    dotfiles.usbWatcher = hs.usb.watcher.new(function(device)
        if isTrigger(device) then later(SETTLE) end
    end):start()
    dotfiles.wakeWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake then later(WAKE_SETTLE) end
    end):start()
end

followMonitor()

-- The volume keys set the monitor's own volume over DDC/CI while the output is one macOS can't set
-- the volume of, as over HDMI or DisplayPort; other outputs keep macOS's keys. Many monitors have
-- no DDC mute, so mute sets the volume to 0 and keeps the old one for unmute. Needs m1ddc, from the
-- Brewfile; without it the keys stay macOS's. Speakers on a monitor's audio out may not follow its
-- volume, as a line-out often doesn't.
local M1DDC = "/opt/homebrew/bin/m1ddc"
-- macOS's steps are sixteenths, and Shift+Option's quarters of those
local VOLUME_STEP, FINE_STEP = 6, 1
local MAX_VOLUME, READ_TRIES = 100, 8
local MUTED_VOLUME = "dotfiles.monitorMutedVolume"
local VOLUME_KEYS = { SOUND_UP = 1, SOUND_DOWN = -1, MUTE = 0 }

-- Presses while m1ddc runs add up, so holding a key doesn't queue a task per repeat. level is the
-- monitor's volume during a run of presses, forgotten once they stop, so a change in the
-- monitor's menu counts.
local volume = { pending = 0, mute = false }

local function monitorOutput()
    if not hs.fs.attributes(M1DDC) then return false end
    local device = hs.audiodevice.defaultOutputDevice()
    if not device or device:outputVolume() ~= nil then return false end
    local transport = device:transportType()
    return transport == "HDMI" or transport == "DisplayPort"
end

local function showVolume(text)
    if volume.alert then hs.alert.closeSpecific(volume.alert) end
    volume.alert = hs.alert.show("Monitor volume " .. text, 0.8)
end

-- A failure drops the presses pending, so the next press starts afresh
local function failed(message)
    volume.task, volume.level, volume.pending, volume.mute = nil, nil, 0, false
    hs.alert.show(message)
end

local function m1ddc(args, onDone)
    local task
    task = hs.task.new(M1DDC, function(exitCode, stdout, stderr)
        dotfiles.tasks[task] = nil
        if exitCode ~= 0 then
            print("m1ddc: " .. stdout .. stderr)
            failed("Couldn't set the monitor's volume; see Hammerspoon's console")
            return
        end
        volume.task = nil
        onDone(stdout)
    end, args)
    if not (task and task:start()) then
        failed("Couldn't run " .. M1DDC .. "; re-run the homebrew step")
        return
    end
    dotfiles.tasks[task] = true
    volume.task = task
end

-- Some monitors answer about a third of reads with junk, such as 110 or 128, so a read counts once
-- two in a row agree on a volume the monitor can have. m1ddc's chg trusts a single read, so isn't
-- used.
local function readVolume(onLevel, tries, last)
    tries = tries or READ_TRIES
    m1ddc({ "get", "volume" }, function(stdout)
        local level = tonumber(stdout:match("^%s*(%d+)%s*$"))
        if level and level > MAX_VOLUME then level = nil end
        if level and level == last then return onLevel(level) end
        if tries <= 1 then return failed("Couldn't read the monitor's volume") end
        readVolume(onLevel, tries - 1, level)
    end)
end

local runVolume

local function setVolume(level, text)
    m1ddc({ "set", "volume", tostring(level) }, function()
        volume.level = level
        showVolume(text or tostring(level))
        runVolume()
    end)
end

runVolume = function()
    if volume.task then return end
    local muted = hs.settings.get(MUTED_VOLUME)
    if not volume.mute and volume.pending == 0 then
        volume.level = nil
    elseif not muted and not volume.level then
        readVolume(function(level)
            volume.level = level
            runVolume()
        end)
    elseif volume.mute then
        volume.mute = false
        if muted then
            hs.settings.clear(MUTED_VOLUME)
            setVolume(muted)
        else
            hs.settings.set(MUTED_VOLUME, volume.level)
            setVolume(0, "muted")
        end
    else
        local delta = volume.pending
        volume.pending = 0
        if not muted then
            setVolume(math.max(0, math.min(MAX_VOLUME, volume.level + delta)))
        elseif delta > 0 then
            -- Up unmutes, as macOS's does
            hs.settings.clear(MUTED_VOLUME)
            setVolume(math.min(MAX_VOLUME, muted + delta))
        else
            showVolume("muted")
        end
    end
end

-- Each key sends a down and an up; both are swallowed so macOS doesn't show its "can't" sign
dotfiles.volumeTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(event)
    local key = event:systemKey()
    local direction = VOLUME_KEYS[key.key or ""]
    if not direction or not monitorOutput() then return false end
    if key.down then
        if direction == 0 then
            if not key["repeat"] then volume.mute = not volume.mute end
        else
            local flags = event:getFlags()
            local step = (flags.shift and flags.alt) and FINE_STEP or VOLUME_STEP
            volume.pending = volume.pending + direction * step
        end
        runVolume()
    end
    return true
end):start()
