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

local function PushBuiltInAlert(messageStr)
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end

    local okAlerts, alertWidgets = pcall(FindAllOf, "WBP_PlayerAlerts_C")
    if not okAlerts or not alertWidgets or #alertWidgets == 0 then
        return false
    end

    local pushed = false
    for _, w in ipairs(alertWidgets) do
        if Core.IsValidObj(w) and Core.IsValidObj(w.Container) then
            local entryW = Core.CreateUserWidget(PATHS.WBPPlayerAlertStatusClass, w, pc)
            if Core.IsValidObj(entryW) then
                pcall(function()
                    if Core.IsValidObj(entryW.WBP_RichText) then
                        entryW.WBP_RichText:SetText(Core.MakeText(messageStr))
                    end
                    if w.Container.AddChildToVerticalBox then
                        w.Container:AddChildToVerticalBox(entryW)
                    else
                        w.Container:AddChild(entryW)
                    end
                    pushed = true
                end)
                ExecuteInGameThreadWithDelay(6000, function()
                    if Core.IsValidObj(entryW) then
                        pcall(function() entryW:RemoveSelf() end)
                    end
                end)
            end
        end
    end
    return pushed
end

local function PollPlayerPresence()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local players = StationData.GetAllPlayersInfo(pc)
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
        ExecuteInGameThreadWithDelay(1000, Tick)
    end
    ExecuteInGameThreadWithDelay(1000, Tick)
end

function Feature.Init()
    StartPoll()
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "PC_AddRemotePlayer_Alert",
        "/Script/MainSequence.DMSPlayerController:Client_AddRemotePlayer",
        function()
            ExecuteInGameThreadWithDelay(250, PollPlayerPresence)
        end
    )
    Core.TryRegisterHook(
        "PC_RemovePlayer_Alert",
        "/Script/MainSequence.DMSPlayerController:Client_RemovePlayer",
        function()
            ExecuteInGameThreadWithDelay(250, PollPlayerPresence)
        end
    )
end

function Feature.OnClientRestart()
    ExecuteInGameThreadWithDelay(1200, PollPlayerPresence)
end

return Feature
