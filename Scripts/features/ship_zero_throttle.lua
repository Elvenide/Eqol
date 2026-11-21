-- Eqol Feature: Ship Instant Zero Throttle
-- Configurable keybind (default 0 / Zero) to instantly set ship throttle/acceleration to 0.

local Core = require("core")

local Feature = {
    Name        = "ShipZeroThrottle",
    DisplayName = "Ship Instant Zero Throttle",
    Description = "Hotkey (default 0) to immediately set ship throttle to zero.",
}

local LoggedDiag = false

local function IsPilotingShipNow()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end
    if Core.IsAnyBlockingMenuOpen and Core.IsAnyBlockingMenuOpen() then return false end
    local ok, po = pcall(function() return pc.PlayerObject end)
    return ok and Core.IsValidObj(po) and Core.IsValidObj(po.PilotedShip)
end

local function ZeroShipThrottle()
    if not Core.IsFeatureEnabled("ShipZeroThrottle") then return end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) or not Core.IsValidObj(playerObj.PilotedShip) then
        return
    end

    local shipObj = playerObj.PilotedShip
    local calledRpc = false
    for _, fnName in ipairs({ "SetThrottleInput", "SetThrottle", "SetTargetThrottle", "ZeroThrottle" }) do
        local okFn, fn = pcall(function() return pc[fnName] end)
        if okFn and fn ~= nil then
            local okCall = pcall(function() pc[fnName](pc, 0.0) end)
            if okCall then
                calledRpc = true
                Core.Log("[ShipZeroThrottle] Called pc:" .. fnName .. "(0.0)")
                break
            end
        end
    end

    if not calledRpc then
        for _, fnName in ipairs({ "SetThrottle", "SetTargetThrottle", "SetThrottleInput", "SetTargetSpeed" }) do
            local okFn, fn = pcall(function() return shipObj[fnName] end)
            if okFn and fn ~= nil then
                local okCall = pcall(function() shipObj[fnName](shipObj, 0.0) end)
                if okCall then
                    calledRpc = true
                    Core.Log("[ShipZeroThrottle] Called shipObj:" .. fnName .. "(0.0)")
                    break
                end
            end
        end
    end

    if not calledRpc then
        -- Fallback: zero throttle properties on shipObj directly if no RPC matched
        local touched = {}
        for _, prop in ipairs({ "Throttle", "TargetThrottle", "ThrottleStep", "CurrentThrottle", "TargetSpeed" }) do
            pcall(function()
                if shipObj[prop] ~= nil then
                    shipObj[prop] = 0
                    touched[#touched + 1] = prop
                end
            end)
        end
        if not LoggedDiag then
            LoggedDiag = true
            Core.Log("[ShipZeroThrottle] Fallback props touched: " .. table.concat(touched, ", "))
        end
    end
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "ShipZeroThrottleKey",
        DefaultKey  = "Zero",
        MappingName = "Eqol_ShipZeroThrottle",
        Label       = "Ship Zero Throttle",
        CanTrigger  = IsPilotingShipNow,
        OnPress     = ZeroShipThrottle,
    })
end

return Feature
