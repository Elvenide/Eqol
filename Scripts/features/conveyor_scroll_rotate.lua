-- Eqol Feature: Scroll-to-Rotate Station Machines
-- Allows rotating any machine/conveyor builder on a station with the mouse scroll wheel in addition to R.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "ConveyorScrollRotate",
}

local PollActive = false
local CachedStationCheck = { time = -999, inStation = false }

local function IsInStationCached(pc)
    local now = os.clock()
    if (now - CachedStationCheck.time) < 0.5 then
        return CachedStationCheck.inStation
    end
    CachedStationCheck.time = now
    local inSt = StationData.IsPlayerInStation(pc)
    CachedStationCheck.inStation = (inSt == true)
    return CachedStationCheck.inStation
end

local function GetActiveStationBuilder(pc)
    if not Core.IsValidObj(pc) then return nil end

    for _, prop in ipairs({ "ActiveBuilder", "CurrentBuilder", "Builder" }) do
        local ok, b = pcall(function() return pc[prop] end)
        if ok and Core.IsValidObj(b) then
            local hasAddRot = false
            pcall(function() hasAddRot = (b.AddRotation ~= nil) end)
            if hasAddRot then
                return b
            end
        end
    end

    return nil
end

local function StartScrollRotatePoll()
    if PollActive then return end
    PollActive = true

    local kScrollUp = { KeyName = FName("MouseScrollUp") }
    local kScrollDown = { KeyName = FName("MouseScrollDown") }
    local kWheelAxis = { KeyName = FName("MouseWheelAxis") }

    local function Tick()
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and not pc.bShowMouseCursor then
            local builder = GetActiveStationBuilder(pc)
            if Core.IsValidObj(builder) and IsInStationCached(pc) then
                local delta = 0
                pcall(function()
                    if pc:WasInputKeyJustPressed(kScrollUp) then
                        delta = 1
                    elseif pc:WasInputKeyJustPressed(kScrollDown) then
                        delta = -1
                    else
                        local axis = pc:GetInputAnalogKeyState(kWheelAxis)
                        if type(axis) == "number" then
                            if axis > 0.01 then
                                delta = 1
                            elseif axis < -0.01 then
                                delta = -1
                            end
                        end
                    end
                end)
                if delta ~= 0 then
                    pcall(function() builder:AddRotation(delta) end)
                end
            end
        end
        -- Run every game frame so single-frame scroll events are never missed
        ExecuteInGameThreadAfterFrames(1, Tick)
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

function Feature.Init()
    StartScrollRotatePoll()
end

return Feature
