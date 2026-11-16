-- Eqol Feature: Cinematic Freecam Toggle
-- Configurable keybind (default F9) that toggles Spectator Mode and Hide HUD simultaneously.

local Core = require("core")

local Feature = {
    Name = "CinematicFreecam",
}

local FreecamActive = false

local function SetHudHiddenState(pc, hidden)
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) then
        pcall(function()
            if hidden then
                widgetSub:HideHUD()
            else
                widgetSub:ShowHUD()
            end
        end)
    end

    local ok, huds = pcall(FindAllOf, "WBP_CharacterHUD_C")
    if ok and huds then
        for _, hud in ipairs(huds) do
            if Core.IsValidObj(hud) then
                pcall(function() hud:SetHUDHidden(hidden) end)
            end
        end
    end
end

local function ToggleCinematicFreecam()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    FreecamActive = not FreecamActive

    local okSet = pcall(function() pc:SetSpectatorMode(FreecamActive) end)
    if not okSet then
        pcall(function() pc:ToggleSpectatorMode() end)
    end

    SetHudHiddenState(pc, FreecamActive)
    Core.Log("Cinematic Freecam: " .. (FreecamActive and "ON" or "OFF"))
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "CinematicFreecamKey",
        DefaultKey  = "F9",
        MappingName = "Eqol_CinematicFreecam",
        Label       = "Cinematic Freecam",
        OnPress     = ToggleCinematicFreecam,
    })
end

function Feature.OnClientRestart()
    FreecamActive = false
end

return Feature
