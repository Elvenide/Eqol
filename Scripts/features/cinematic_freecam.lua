-- Eqol Feature: Cinematic Freecam Toggle
-- Configurable keybind (default C) that toggles built-in Spectator Mode and Hide HUD simultaneously.

local Core = require("core")

local Feature = {
    Name = "CinematicFreecam",
}

local FreecamActive = false

local function GetSpectatorModeState(pc)
    if not Core.IsValidObj(pc) then return nil end
    local ok, val = pcall(function()
        return pc.PlayerObject.SpectatorView.bSpectatorMode
    end)
    if ok and type(val) == "boolean" then
        return val
    end
    return nil
end

local function ToggleCinematicFreecam()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    pcall(function() pc:ToggleSpectatorMode() end)

    local isSpec = GetSpectatorModeState(pc)
    if isSpec == nil then
        isSpec = not FreecamActive
    end
    FreecamActive = isSpec

    pcall(function() pc:SetHUDHidden(isSpec) end)
    ExecuteInGameThreadWithDelay(50, function()
        if Core.IsValidObj(pc) then
            local updatedSpec = GetSpectatorModeState(pc)
            if updatedSpec ~= nil then
                FreecamActive = updatedSpec
                pcall(function() pc:SetHUDHidden(updatedSpec) end)
            else
                pcall(function() pc:SetHUDHidden(isSpec) end)
            end
        end
    end)

    Core.Log("Cinematic Freecam: " .. (isSpec and "ON" or "OFF"))
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "CinematicFreecamKey",
        DefaultKey  = "C",
        MappingName = "Eqol_CinematicFreecam",
        Label       = "Cinematic Freecam",
        OnPress     = ToggleCinematicFreecam,
    })
end

function Feature.OnClientRestart()
    if FreecamActive then
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) then
            local isSpec = GetSpectatorModeState(pc)
            if isSpec == true then
                pcall(function() pc:ToggleSpectatorMode() end)
            end
            pcall(function() pc:SetHUDHidden(false) end)
        end
        FreecamActive = false
    end
end

return Feature
