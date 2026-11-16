-- Eqol Feature: Cinematic Freecam Toggle
-- Configurable keybind (default C) that toggles built-in Spectator Mode and Hide HUD simultaneously.

local Core = require("core")

local Feature = {
    Name = "CinematicFreecam",
}

local FreecamActive = false
local LoggedSpectatorSig = false

local function LogSpectatorReflection(pc)
    if LoggedSpectatorSig or not Core.IsValidObj(pc) then return end
    LoggedSpectatorSig = true
    pcall(function()
        local cls = pc:GetClass()
        if Core.IsValidObj(cls) and cls.ForEachFunction then
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if n == "SetSpectatorMode" or n == "UpdateSpectatorTransform" then
                    local params = {}
                    if fn.ForEachProperty then
                        fn:ForEachProperty(function(prop)
                            params[#params + 1] = prop:GetFName():ToString() .. ":" .. prop:GetClass():GetFName():ToString()
                        end)
                    end
                    Core.Log("Freecam Sig [" .. n .. "]: " .. table.concat(params, ", "))
                end
            end)
        end
    end)
end

local function ToggleCinematicFreecam()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    LogSpectatorReflection(pc)
    FreecamActive = not FreecamActive

    pcall(function() pc:SetSpectatorMode(FreecamActive) end)
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
