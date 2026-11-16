-- Eqol Feature: Ship Instant Zero Throttle
-- Configurable keybind (default 0 / Zero) to instantly set ship throttle/acceleration to 0.

local Core = require("core")

local Feature = {
    Name = "ShipZeroThrottle",
}

local function ZeroShipThrottle()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) or not Core.IsValidObj(playerObj.PilotedShip) then
        return
    end

    local shipObj = playerObj.PilotedShip
    pcall(function() pc:SetThrottleInput(0.0) end)

    for _, prop in ipairs({ "Throttle", "TargetThrottle", "ThrottleStep", "CurrentThrottle" }) do
        pcall(function()
            if shipObj[prop] ~= nil then
                shipObj[prop] = 0
            end
        end)
    end
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
