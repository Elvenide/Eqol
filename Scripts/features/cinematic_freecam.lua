-- Eqol Feature: Cinematic Freecam Toggle
-- Configurable keybind (default C) that toggles built-in Spectator Mode and Hide HUD simultaneously.

local Core = require("core")

local Feature = {
    Name = "CinematicFreecam",
}

local FreecamActive = false
local LoggedSettingsSpectator = false

Feature.WatchWidgets = {
    WBP_SettingsMenu_C = function(menu)
        if LoggedSettingsSpectator or not Core.IsValidObj(menu) then return end
        LoggedSettingsSpectator = true
        pcall(function()
            local cls = menu:GetClass()
            if Core.IsValidObj(cls) and cls.ForEachFunction then
                cls:ForEachFunction(function(fn)
                    local n = fn:GetFName():ToString()
                    if string.find(n, "Spectat", 1, true) or string.find(n, "HUD", 1, true) then
                        Core.Log("Freecam Reflection [SettingsMenu fn]: " .. n)
                    end
                end)
            end
            if Core.IsValidObj(cls) and cls.ForEachProperty then
                cls:ForEachProperty(function(prop)
                    local n = prop:GetFName():ToString()
                    if string.find(n, "Spectat", 1, true) or string.find(n, "HUD", 1, true) then
                        Core.Log("Freecam Reflection [SettingsMenu prop]: " .. n)
                    end
                end)
            end
        end)
    end,
}

local function ToggleCinematicFreecam()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    FreecamActive = not FreecamActive

    pcall(function() pc:SetSpectatorMode(FreecamActive) end)
    pcall(function() pc:UpdateSpectatorTransform() end)
    pcall(function() pc:SetHUDHidden(FreecamActive) end)
    Core.Log("Cinematic Freecam: " .. (FreecamActive and "ON" or "OFF"))
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
        FreecamActive = false
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) then
            pcall(function() pc:SetSpectatorMode(false) end)
            pcall(function() pc:SetHUDHidden(false) end)
        end
    end
end

return Feature
