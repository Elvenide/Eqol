-- Eqol Feature: Ship Instant Zero Throttle
-- Configurable keybind (default 0 / Zero) to instantly set ship throttle/acceleration to 0.

local Core = require("core")

local Feature = {
    Name        = "ShipZeroThrottle",
    DisplayName = "Ship Instant Zero Throttle",
    Description = "Hotkey (default 0) to immediately set ship throttle to zero.",
}

local ZeroToken = 0
local KEY_W = nil
local KEY_S = nil

local function EnsureManualKeys()
    if KEY_W == nil then
        pcall(function() KEY_W = { KeyName = FName("W") } end)
        pcall(function() KEY_S = { KeyName = FName("S") } end)
    end
end

local function ReadShipThrottle(shipObj)
    if not Core.IsValidObj(shipObj) then return nil end
    local ok, val = pcall(function() return shipObj.Throttle end)
    if not ok or val == nil then return nil end
    if type(val) == "number" then
        return val
    end
    -- Handle fixed-point PFloat/PNum struct if applicable
    local okV, rawV = pcall(function() return val.Value end)
    if okV and type(rawV) == "number" then
        return rawV / 65536.0
    end
    return nil
end

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
    local startThrottle = ReadShipThrottle(shipObj)
    Core.Log(string.format("[ShipZeroThrottle] Triggered: curThrottle=%s", tostring(startThrottle)))

    if startThrottle == nil or math.abs(startThrottle) < 0.0001 then
        pcall(function() pc:SetThrottleInput(0.0) end)
        return
    end

    EnsureManualKeys()
    ZeroToken = ZeroToken + 1
    local myToken = ZeroToken
    local startSign = (startThrottle > 0) and 1 or -1
    local deadline = os.clock() + 2.5

    -- Step throttle cleanly to exact 0 via the native SetThrottleInput axis (-1.0 / +1.0 -> 0.0)
    local function Step()
        if myToken ~= ZeroToken then return end
        local curPC = Core.GetLocalPlayerController()
        if not Core.IsValidObj(curPC) then return end

        local po = curPC.PlayerObject
        local curShip = Core.IsValidObj(po) and po.PilotedShip or nil
        if not Core.IsValidObj(curShip) then
            pcall(function() curPC:SetThrottleInput(0.0) end)
            return
        end

        -- Abort immediately if the player manually presses W or S
        local manualOverride = false
        pcall(function()
            if (KEY_W and curPC:IsInputKeyDown(KEY_W)) or (KEY_S and curPC:IsInputKeyDown(KEY_S)) then
                manualOverride = true
            end
        end)
        if manualOverride then return end

        local cur = ReadShipThrottle(curShip)
        if cur == nil or math.abs(cur) < 0.0001 or (startSign > 0 and cur <= 0) or (startSign < 0 and cur >= 0) or os.clock() >= deadline then
            pcall(function() curPC:SetThrottleInput(0.0) end)
            Core.Log(string.format("[ShipZeroThrottle] Stopped at throttle=%s", tostring(cur)))
            return
        end

        local inputDir = (cur > 0) and -1.0 or 1.0
        pcall(function() curPC:SetThrottleInput(inputDir) end)
        ExecuteInGameThreadAfterFrames(1, Step)
    end

    Step()
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
