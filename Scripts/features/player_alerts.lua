-- Eqol Feature: Player Join / Leave Alerts
-- Uses Main Sequence's built-in WBP_PlayerAlerts_C / PlayerAlertStatus alerting system
-- to notify when players (including the host) join or leave the game.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "PlayerAlerts",
}

local PATHS = {
    PlayerAlertStatusClass    = "/Script/MainSequence.PlayerAlertStatus",
    WBPPlayerAlertStatusClass = "/Game/Blueprints/Widgets/HUDs/WBP_PlayerAlertStatus.WBP_PlayerAlertStatus_C",
}

local KnownOnlinePlayers = {} -- playerKey -> { Name = string, IsOnline = bool }
local InitializedSnapshot = false
local PollActive = false
local CachedAlertWidget = nil
local LastAlertScanTime = -999.0
local ALERT_SCAN_COOLDOWN = 8.0   -- Safety-net FindAllOf interval (>= 8s per learning.md §7)
local PRESENCE_POLL_MS    = 8000  -- Safety-net presence poll (join/leave hooks fire immediately)

local function PushBuiltInAlert(messageStr)
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end

    local targetWidget = nil
    if Core.IsValidObj(CachedAlertWidget) and Core.IsValidObj(CachedAlertWidget.Container) then
        targetWidget = CachedAlertWidget
    else
        CachedAlertWidget = nil
        local now = os.clock()
        if (now - LastAlertScanTime) >= ALERT_SCAN_COOLDOWN then
            LastAlertScanTime = now
            local okAlerts, found = pcall(FindAllOf, "WBP_PlayerAlerts_C")
            if okAlerts and found and #found > 0 then
                -- Pick a single active in-viewport WBP_PlayerAlerts_C to avoid duplicate alerts
                local fallback = nil
                for _, w in ipairs(found) do
                    if Core.IsValidObj(w) and Core.IsValidObj(w.Container) then
                        if not fallback then fallback = w end
                        local okVP, inVP = pcall(function() return w:IsInViewport() end)
                        local okVis, isVis = pcall(function() return w:IsVisible() end)
                        if (okVP and inVP) or (okVis and isVis) then
                            targetWidget = w
                            break
                        end
                    end
                end
                targetWidget = targetWidget or fallback
                if Core.IsValidObj(targetWidget) then
                    CachedAlertWidget = targetWidget
                end
            end
        end
    end
    if not Core.IsValidObj(targetWidget) or not Core.IsValidObj(targetWidget.Container) then
        return false
    end

    local pushed = false
    local entryW = Core.CreateUserWidget(PATHS.WBPPlayerAlertStatusClass, targetWidget, pc)
    if Core.IsValidObj(entryW) then
        pcall(function()
            if Core.IsValidObj(entryW.WBP_RichText) then
                entryW.WBP_RichText:SetText(Core.MakeText(messageStr))
            end
            if targetWidget.Container.AddChildToVerticalBox then
                targetWidget.Container:AddChildToVerticalBox(entryW)
            else
                targetWidget.Container:AddChild(entryW)
            end
            pushed = true
        end)
        ExecuteInGameThreadWithDelay(6000, function()
            if Core.IsValidObj(entryW) then
                pcall(function()
                    if entryW.RemoveSelf then
                        entryW:RemoveSelf()
                    elseif entryW.RemoveFromParent then
                        entryW:RemoveFromParent()
                    end
                end)
            end
        end)
    end
    return pushed
end

local function PollPlayerPresence(forceRefresh)
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) or not Core.IsValidObj(pc.PlayerObject) then return end

    local players = StationData.GetAllPlayersInfo(pc, forceRefresh == true)
    if #players == 0 then return end

    if not InitializedSnapshot then
        -- Wait until WBP_PlayerAlerts_C actually exists in-game before marking snapshot initialized
        local localJoined = false
        for _, p in ipairs(players) do
            if p.IsLocal and p.IsOnline then
                if PushBuiltInAlert(string.format("%s joined the game", p.Name)) then
                    localJoined = true
                end
                break
            end
        end
        if localJoined then
            InitializedSnapshot = true
            for _, p in ipairs(players) do
                KnownOnlinePlayers[p.Key] = { Name = p.Name, IsOnline = p.IsOnline }
            end
        end
        return
    end

    local currentSeen = {}
    for _, p in ipairs(players) do
        currentSeen[p.Key] = true
        local prev = KnownOnlinePlayers[p.Key]
        if not prev then
            KnownOnlinePlayers[p.Key] = { Name = p.Name, IsOnline = p.IsOnline }
            if p.IsOnline then
                PushBuiltInAlert(string.format("%s joined the game", p.Name))
            end
        else
            if p.IsOnline and not prev.IsOnline then
                PushBuiltInAlert(string.format("%s joined the game", p.Name))
            elseif not p.IsOnline and prev.IsOnline then
                PushBuiltInAlert(string.format("%s left the game", p.Name))
            end
            prev.IsOnline = p.IsOnline
            prev.Name = p.Name
        end
    end

    for k, prev in pairs(KnownOnlinePlayers) do
        if not currentSeen[k] then
            if prev.IsOnline then
                PushBuiltInAlert(string.format("%s left the game", prev.Name))
            end
            KnownOnlinePlayers[k] = nil
        end
    end
end

local function StartPoll()
    if PollActive then return end
    PollActive = true
    local function Tick()
        pcall(PollPlayerPresence)
        ExecuteInGameThreadWithDelay(PRESENCE_POLL_MS, Tick)
    end
    ExecuteInGameThreadWithDelay(PRESENCE_POLL_MS, Tick)
end

Feature.WatchWidgets = {
    WBP_PlayerAlerts_C = function(w)
        if Core.IsValidObj(w) then
            CachedAlertWidget = w
            if not InitializedSnapshot then
                ExecuteInGameThreadWithDelay(200, PollPlayerPresence)
            end
        end
    end,
}

function Feature.Init()
    StartPoll()
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "PC_AddRemotePlayer_Alert",
        "/Script/MainSequence.DMSPlayerController:Client_AddRemotePlayer",
        function()
            ExecuteInGameThreadWithDelay(250, function() PollPlayerPresence(true) end)
        end
    )
    Core.TryRegisterHook(
        "PC_RemovePlayer_Alert",
        "/Script/MainSequence.DMSPlayerController:Client_RemovePlayer",
        function()
            ExecuteInGameThreadWithDelay(250, function() PollPlayerPresence(true) end)
        end
    )
end

function Feature.OnClientRestart()
    ExecuteInGameThreadWithDelay(1200, PollPlayerPresence)
end

function Feature.OnMapLoad()
    KnownOnlinePlayers = {}
    InitializedSnapshot = false
    CachedAlertWidget = nil
    LastAlertScanTime = -999.0
end

function Feature.PruneCaches()
    if CachedAlertWidget and not Core.IsValidObj(CachedAlertWidget) then
        CachedAlertWidget = nil
    end
end

return Feature
