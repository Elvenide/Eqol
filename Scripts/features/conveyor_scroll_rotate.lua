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

local ConvBuilderDiagLogged = false

local function IsConveyorBuilderPulling(builder)
    if not Core.IsValidObj(builder) then return false end
    local okCls, cn = pcall(function() return builder:GetClass():GetFName():ToString() end)
    if not okCls or type(cn) ~= "string" or not cn:find("Conveyor", 1, true) then
        return false
    end

    -- Check common state properties indicating a start point has been placed and the belt is being dragged out
    for _, prop in ipairs({
        "bIsPlacing", "bPlacing", "bHasStart", "bHasStartPoint", "bHasStartLocation",
        "bIsDragging", "bDragging", "bBuildingBelt", "bIsBuilding", "bStarted",
    }) do
        local ok, v = pcall(function() return builder[prop] end)
        if ok and v == true then
            return true
        end
    end

    for _, prop in ipairs({ "BuildStage", "Stage", "PlacementStage", "Step", "State", "BuildState" }) do
        local ok, v = pcall(function() return builder[prop] end)
        if ok and type(v) == "number" and v > 0 then
            return true
        end
    end

    for _, prop in ipairs({ "StartPoint", "StartLocation", "StartCell", "FirstPoint", "PathPoints", "BeltPoints", "PreviewBelts", "PreviewActors", "Segments" }) do
        local ok, v = pcall(function() return builder[prop] end)
        if ok and v ~= nil then
            local okLen, len = pcall(function() return v.GetArrayNum and v:GetArrayNum() or #v end)
            if okLen and type(len) == "number" and len > 0 then
                return true
            end
        end
    end

    -- One-time concise property dump if we're scrolling on ConveyorBuilder so we can verify exact field names
    if not ConvBuilderDiagLogged then
        ConvBuilderDiagLogged = true
        local parts = {}
        pcall(function()
            local cls = builder:GetClass()
            while Core.IsValidObj(cls) do
                local cName = cls:GetFName():ToString()
                if cName == "Object" or cName == "Actor" then break end
                cls:ForEachProperty(function(prop)
                    local pn = prop:GetFName():ToString()
                    local okV, val = pcall(function() return builder[pn] end)
                    if okV and val ~= nil and (type(val) == "boolean" or type(val) == "number") then
                        parts[#parts + 1] = pn .. "=" .. tostring(val)
                    elseif okV and val ~= nil and type(val) == "userdata" then
                        local okN, n = pcall(function() return val.GetArrayNum and val:GetArrayNum() end)
                        if okN and type(n) == "number" then
                            parts[#parts + 1] = pn .. "[" .. tostring(n) .. "]"
                        end
                    end
                end)
                cls = cls:GetSuperStruct()
            end
        end)
        Core.Log("[ScrollRotate] ConveyorBuilder props: " .. table.concat(parts, ", "))
    end

    return false
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
                    local pullingBelt = IsConveyorBuilderPulling(builder)
                    local steps = 1
                    if pullingBelt then
                        -- While pulling out a conveyor belt, routing toggles between 2 elbow modes;
                        -- calling AddRotation(1) once works for both scroll up and scroll down.
                        steps = 1
                    elseif delta == 1 then
                        -- Reversed direction: Scroll Up rotates -90 deg (+3 mod 4)
                        steps = 3
                    else
                        -- Reversed direction: Scroll Down rotates +90 deg (+1 mod 4)
                        steps = 1
                    end
                    pcall(function()
                        for _ = 1, steps do
                            builder:AddRotation(1)
                        end
                    end)
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
