-- Eqol Feature: Scroll-to-Rotate Station Machines
-- Allows rotating any machine/conveyor builder on a station with the mouse scroll wheel in addition to R.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "ConveyorScrollRotate",
    DisplayName = "Scroll-to-Rotate Station Machines",
    Description = "Rotate station machines and conveyor belts using the mouse scroll wheel.",
}

local PollActive = false
local CachedStationCheck = { time = -999, inStation = false }
local ConveyorPullingActive = false
local LastConveyorBuilderAddr = nil
local LastBeltSpawnClock = -999.0
local LastLocalConfirmClock = -999.0
local BeltSpawnHookRegistered = false

local function IsLocalPC(pc)
    if not Core.IsValidObj(pc) then return false end
    local ok, isLoc = pcall(function() return pc:IsLocalPlayerController() end)
    if ok and type(isLoc) == "boolean" then
        return isLoc
    end
    local localPC = Core.GetLocalPlayerController()
    return Core.IsValidObj(localPC) and localPC:GetAddress() == pc:GetAddress()
end

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

    -- Check verified pc.Builder first to avoid probing non-existent properties every frame (learning.md §8)
    local okB, b = pcall(function() return pc.Builder end)
    if okB and Core.IsValidObj(b) then
        local hasAddRot = false
        pcall(function() hasAddRot = (b.AddRotation ~= nil) end)
        if hasAddRot then
            return b
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
        if not Core.IsFeatureEnabled("ConveyorScrollRotate") then
            PollActive = false
            ConveyorPullingActive = false
            return
        end
        local pc = Core.GetLocalPlayerController()
        local activeBuilding = false
        if Core.IsValidObj(pc) and not pc.bShowMouseCursor then
            local builder = GetActiveStationBuilder(pc)
            if Core.IsValidObj(builder) and IsInStationCached(pc) then
                activeBuilding = true
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
        else
            LastConveyorBuilderAddr = nil
            ConveyorPullingActive = false
        end
        -- Run every frame while actively building so single-frame scroll events are never missed;
        -- back off to 100ms when idle/not building.
        if activeBuilding then
            ExecuteInGameThreadAfterFrames(1, Tick)
        else
            ExecuteInGameThreadWithDelay(100, Tick)
        end
    end

    ExecuteInGameThreadWithDelay(100, Tick)
end

local function ResetState()
    ConveyorPullingActive = false
    LastConveyorBuilderAddr = nil
    LastBeltSpawnClock = -999.0
    LastLocalConfirmClock = -999.0
    CachedStationCheck = { time = -999, inStation = false }
end

function Feature.RegisterHooks()
    if not BeltSpawnHookRegistered then
        BeltSpawnHookRegistered = true
        pcall(NotifyOnNewObject, "/Script/MainSequence.ConveyorBeltObject", function(obj)
            if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
            if not Core.IsValidObj(obj) then return end
            -- Marshal onto game thread and only clear local pulling state if the local player recently confirmed a build
            -- AND the belt spawned on the local player's current frame (prevents remote MP builds from cancelling local pull).
            ExecuteInGameThread(function()
                if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
                local now = os.clock()
                if (now - LastLocalConfirmClock) <= 0.35 then
                    local sameFrame = true
                    pcall(function()
                        local localPC = Core.GetLocalPlayerController()
                        local localFrame = Core.IsValidObj(localPC) and Core.IsValidObj(localPC.PlayerObject)
                            and localPC.PlayerObject.GetFrame and localPC.PlayerObject:GetFrame() or nil
                        local objFrame = Core.IsValidObj(obj) and obj.GetFrame and obj:GetFrame() or nil
                        if Core.IsValidObj(localFrame) and Core.IsValidObj(objFrame) then
                            sameFrame = (localFrame:GetAddress() == objFrame:GetAddress())
                        end
                    end)
                    if sameFrame then
                        LastBeltSpawnClock = now
                        ConveyorPullingActive = false
                    end
                end
            end)
        end)
    end
    Core.TryRegisterHook(
        "ScrollRotate_ConfirmBuild",
        "/Script/MainSequence.DMSPlayerController:ConfirmBuild",
        function(Context)
            if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
            local pc = Context and Context:get() or nil
            if not IsLocalPC(pc) then return end
            local clickClock = os.clock()
            LastLocalConfirmClock = clickClock
            ExecuteInGameThreadWithDelay(80, function()
                if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
                -- If real ConveyorBeltObject(s) were spawned by this ConfirmBuild, the pulled segments
                -- were committed and ConveyorBuilder is back in non-pulling mode.
                if LastBeltSpawnClock >= clickClock - 0.05 then
                    ConveyorPullingActive = false
                    return
                end
                local curPC = Core.GetLocalPlayerController()
                if not Core.IsValidObj(curPC) then return end
                local builder = GetActiveStationBuilder(curPC)
                if IsConveyorBuilder(builder) then
                    LastConveyorBuilderAddr = builder:GetAddress()
                    ConveyorPullingActive = true
                else
                    ConveyorPullingActive = false
                end
            end)
        end
    )
    Core.TryRegisterHook(
        "ScrollRotate_ExitBuildMode",
        "/Script/MainSequence.DMSPlayerController:ExitBuildingMode",
        function(Context)
            if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
            local pc = Context and Context:get() or nil
            if not IsLocalPC(pc) then return end
            ConveyorPullingActive = false
            LastConveyorBuilderAddr = nil
        end
    )
end

function Feature.OnToggle(enabled)
    if enabled then
        StartScrollRotatePoll()
    else
        ConveyorPullingActive = false
    end
end

function Feature.Init()
    if Core.IsFeatureEnabled("ConveyorScrollRotate") then
        StartScrollRotatePoll()
    end
end

function Feature.OnMapLoad()
    ResetState()
end

function Feature.OnClientRestart()
    ResetState()
end

return Feature
