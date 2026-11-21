-- Eqol Feature: Ship Instant Zero Throttle
-- Configurable keybind (default 0 / Zero) to instantly set ship throttle/acceleration to 0.

local Core = require("core")

local Feature = {
    Name        = "ShipZeroThrottle",
    DisplayName = "Ship Instant Zero Throttle",
    Description = "Hotkey (default 0) to immediately set ship throttle to zero.",
}

local function ZeroShipThrottle()
    if not Core.IsFeatureEnabled("ShipZeroThrottle") then return end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) or not Core.IsValidObj(playerObj.PilotedShip) then
        return
    end

    -- Use the verified native PlayerController RPC only (never write directly to PilotedShip simulation properties)
    pcall(function() pc:SetThrottleInput(0.0) end)
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "ShipZeroThrottleKey",
        DefaultKey  = "Zero",
        MappingName = "Eqol_ShipZeroThrottle",
        Label       = "Ship Zero Throttle",
        OnPress     = ZeroShipThrottle,
    })
end

return Feature
