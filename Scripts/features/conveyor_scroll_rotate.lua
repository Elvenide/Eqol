-- Eqol Feature: Scroll-to-Rotate Station Machines
-- Allows rotating any machine/conveyor builder on a station with the mouse scroll wheel in addition to R.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "ConveyorScrollRotate",
}

local PollActive = false
local CachedStationCheck = { time = -999, inStation = false }
local ConveyorPullingActive = false
local LastConveyorBuilderAddr = nil

local function IsConveyorBuilder(builder)
    if not Core.IsValidObj(builder) then return false end
    local okCls, cn = pcall(function() return builder:GetClass():GetFName():ToString() end)
    return okCls and type(cn) == "string" and cn:find("Conveyor", 1, true) ~= nil
end

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
    local kRMB = { KeyName = FName("RightMouseButton") }

    local function Tick()
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and not pc.bShowMouseCursor then
            local builder = GetActiveStationBuilder(pc)
            if Core.IsValidObj(builder) and IsInStationCached(pc) then
                local bAddr = builder:GetAddress()
                if bAddr ~= LastConveyorBuilderAddr then
                    LastConveyorBuilderAddr = bAddr
                    ConveyorPullingActive = false
                end
                if ConveyorPullingActive then
                    local okRmb, rmbPressed = pcall(function() return pc:WasInputKeyJustPressed(kRMB) end)
                    if okRmb and rmbPressed then
                        ConveyorPullingActive = false
                    end
                end

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
                    local pullingBelt = ConveyorPullingActive and IsConveyorBuilder(builder)
                    local steps = 1
                    if pullingBelt then
                        -- While pulling out a conveyor belt, routing cycles through 3 modes:
                        -- Scroll Down = +1 mod 3, Scroll Up = +2 mod 3 (-1, opposite direction).
                        steps = (delta == 1) and 2 or 1
                    elseif delta == 1 then
                        -- Scroll Up rotates -90 deg (+3 mod 4)
                        steps = 3
                    else
                        -- Scroll Down rotates +90 deg (+1 mod 4)
                        steps = 1
                    end
                    pcall(function()
                        for _ = 1, steps do
                            builder:AddRotation(1)
                        end
                    end)
                end
            else
                LastConveyorBuilderAddr = nil
                ConveyorPullingActive = false
            end
        end
        -- Run every game frame so single-frame scroll events are never missed
        ExecuteInGameThreadAfterFrames(1, Tick)
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "ScrollRotate_ConfirmBuild",
        "/Script/MainSequence.DMSPlayerController:ConfirmBuild",
        function()
            local pc = Core.GetLocalPlayerController()
            if not Core.IsValidObj(pc) then return end
            local builder = GetActiveStationBuilder(pc)
            if IsConveyorBuilder(builder) then
                LastConveyorBuilderAddr = builder:GetAddress()
                -- Conveyor building chains continuously on each ConfirmBuild click
                -- until the player right-clicks or exits build mode.
                ConveyorPullingActive = true
            else
                ConveyorPullingActive = false
            end
        end
    )
    Core.TryRegisterHook(
        "ScrollRotate_ExitBuildMode",
        "/Script/MainSequence.DMSPlayerController:ExitBuildingMode",
        function()
            ConveyorPullingActive = false
            LastConveyorBuilderAddr = nil
        end
    )
end

function Feature.Init()
    StartScrollRotatePoll()
end

return Feature
