-- Eqol Shared Station, Floor, Machine & Icon Visibility Helpers
-- Used by station_minimap.lua, station_map.lua, and logistics.lua.

local Core = require("core")

local StationData = {}

local PATHS = {
    StationObjectClass         = "/Script/MainSequence.StationObject",
    StationPlatformObjectClass = "/Script/MainSequence.StationPlatformObject",
    AssemblerObjectClass       = "/Script/MainSequence.AssemblerObject",
    ContainerObjectClass       = "/Script/MainSequence.ContainerObject",
    ConveyorBeltObjectClass    = "/Script/MainSequence.ConveyorBeltObject",
    MachineObjectClass         = "/Script/MainSequence.MachineObject",
    ItemClass                  = "/Script/MainSequence.Item",
}

-- Shared per-machine icon visibility state (keyed by SaveableObject.ID string or address)
-- Value = true means the item icon is hidden in both Station Map and Station Minimap.
local HiddenMachineIcons = {}
local IconToggleListeners = {}

-- Cached UClasses
local CachedClasses = {}
local function GetClassCached(key, path)
    if Core.IsValidObj(CachedClasses[key]) then
        return CachedClasses[key]
    end
    local cls = Core.FindOrLoadClass(path)
    if Core.IsValidObj(cls) then
        CachedClasses[key] = cls
    end
    return cls
end

--------------------------------------------------------------------------------
-- Array / Struct Helpers
--------------------------------------------------------------------------------

function StationData.ForEachArray(arr, fn)
    if not arr then return end
    local usedForEach = pcall(function()
        arr:ForEach(function(idx, elem)
            fn(idx, elem)
        end)
    end)
    if usedForEach then return end

    local okLen, len = pcall(function() return #arr end)
    if okLen and type(len) == "number" then
        for i = 1, len do
            fn(i, arr[i])
        end
    end
end

function StationData.GetObjectKey(obj)
    if not Core.IsValidObj(obj) then return nil end
    local okId, idStr = pcall(function()
        if obj.ID ~= nil then
            return tostring(obj.ID)
        end
        return nil
    end)
    if okId and idStr and idStr ~= "" and idStr ~= "nil" then
        return idStr
    end
    return tostring(obj:GetAddress())
end

--------------------------------------------------------------------------------
-- Shared Icon Visibility Toggles
--------------------------------------------------------------------------------

function StationData.IsMachineIconHidden(machine)
    local key = StationData.GetObjectKey(machine)
    if not key then return false end
    return HiddenMachineIcons[key] == true
end

function StationData.ToggleMachineIcon(machine)
    local key = StationData.GetObjectKey(machine)
    if not key then return false end
    local newHidden = not (HiddenMachineIcons[key] == true)
    if newHidden then
        HiddenMachineIcons[key] = true
    else
        HiddenMachineIcons[key] = nil
    end
    for _, cb in ipairs(IconToggleListeners) do
        pcall(cb, machine, newHidden)
    end
    return newHidden
end

function StationData.OnIconVisibilityChanged(cb)
    if type(cb) == "function" then
        table.insert(IconToggleListeners, cb)
    end
end

--------------------------------------------------------------------------------
-- Player & Station Resolution
--------------------------------------------------------------------------------

function StationData.IsPlayerInStation(pc)
    pc = pc or Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false, nil, nil end

    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return false, nil, nil end

    -- Explicitly exclude when piloting a ship
    if Core.IsValidObj(playerObj.PilotedShip) then
        return false, nil, nil
    end

    local okFrame, walkFrame = pcall(function() return playerObj:GetFrame() end)
    if not okFrame or not Core.IsValidObj(walkFrame) then
        return false, nil, nil
    end

    local stationCls = GetClassCached("StationObject", PATHS.StationObjectClass)
    local platCls = GetClassCached("StationPlatformObject", PATHS.StationPlatformObjectClass)

    local isStationFrame = false
    if Core.IsValidObj(stationCls) and walkFrame:IsA(stationCls) then
        isStationFrame = true
    elseif Core.IsValidObj(platCls) and walkFrame:IsA(platCls) then
        isStationFrame = true
    end

    if not isStationFrame then
        return false, nil, nil
    end

    local station = StationData.ResolveStationFromFrame(walkFrame, pc)
    return true, walkFrame, station
end

function StationData.ResolveStationFromFrame(frame, pc)
    if not Core.IsValidObj(frame) then return nil end

    local stationCls = GetClassCached("StationObject", PATHS.StationObjectClass)
    if Core.IsValidObj(stationCls) and frame:IsA(stationCls) then
        return frame
    end

    -- Check direct properties on StationPlatformObject
    for _, propName in ipairs({ "Station", "ParentStation", "OwnerStation" }) do
        local ok, val = pcall(function() return frame[propName] end)
        if ok and Core.IsValidObj(val) then
            return val
        end
    end

    -- Check DMSWorldSubsystem -> GetObject(ParentID)
    local worldSub = Core.GetWorldSubsystem(pc or Core.GetLocalPlayerController(), Core.PATHS.WorldSubsystemClass)
    if Core.IsValidObj(worldSub) then
        local okPid, pid = pcall(function() return frame.ParentID end)
        if okPid and pid ~= nil then
            local okObj, obj = pcall(function() return worldSub:GetObject(pid) end)
            if okObj and Core.IsValidObj(obj) then
                if not Core.IsValidObj(stationCls) or obj:IsA(stationCls) then
                    return obj
                end
            end
        end

        -- Fallback: match against DMSWorld.Stations
        local okWorld, dmsWorld = pcall(function() return worldSub:GetDMSWorld() end)
        if okWorld and Core.IsValidObj(dmsWorld) and dmsWorld.Stations then
            local frameAddr = frame:GetAddress()
            local matchedStation = nil
            StationData.ForEachArray(dmsWorld.Stations, function(_, elem)
                if matchedStation then return end
                local st = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(st) then
                    local plats = StationData.GetStationPlatforms(st)
                    for _, p in ipairs(plats) do
                        if p:GetAddress() == frameAddr then
                            matchedStation = st
                            return
                        end
                    end
                end
            end)
            if matchedStation then
                return matchedStation
            end
        end
    end

    return nil
end

function StationData.GetStationPlatforms(station)
    local result = {}
    if not Core.IsValidObj(station) then return result end

    local seen = {}
    local function addPlat(p)
        if Core.IsValidObj(p) then
            local addr = p:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                table.insert(result, p)
            end
        end
    end

    for _, propName in ipairs({ "Platforms", "Modules", "StationPlatforms", "ConnectedFrames", "Children" }) do
        local ok, arr = pcall(function() return station[propName] end)
        if ok and arr then
            StationData.ForEachArray(arr, function(_, elem)
                addPlat(Core.UnwrapArrayElem(elem))
            end)
            if #result > 0 then
                return result
            end
        end
    end

    -- Fallback: scan live StationPlatformObject instances belonging to this station
    local okAll, allPlats = pcall(FindAllOf, "StationPlatformObject")
    if okAll and allPlats then
        local stAddr = station:GetAddress()
        local stId = StationData.GetObjectKey(station)
        for _, p in ipairs(allPlats) do
            if Core.IsValidObj(p) then
                local belongs = false
                for _, propName in ipairs({ "Station", "ParentStation", "OwnerStation" }) do
                    local okS, sVal = pcall(function() return p[propName] end)
                    if okS and Core.IsValidObj(sVal) and sVal:GetAddress() == stAddr then
                        belongs = true
                        break
                    end
                end
                if not belongs and stId then
                    local okPid, pid = pcall(function() return p.ParentID end)
                    if okPid and pid ~= nil and tostring(pid) == stId then
                        belongs = true
                    end
                end
                if belongs then
                    addPlat(p)
                end
            end
        end
    end

    return result
end

--------------------------------------------------------------------------------
-- Spatial, Floor, and Bounds Helpers
--------------------------------------------------------------------------------

function StationData.GetObjectActor(obj)
    if not Core.IsValidObj(obj) then return nil end
    for _, fnName in ipairs({ "GetActor", "GetSpawnedActor" }) do
        local okFn, actor = pcall(function()
            if type(obj[fnName]) == "function" then
                return obj[fnName](obj)
            end
            return nil
        end)
        if okFn and Core.IsValidObj(actor) then
            return actor
        end
    end
    for _, propName in ipairs({ "Actor", "SpawnedActor", "MachineActor", "PlatformActor" }) do
        local okP, actor = pcall(function() return obj[propName] end)
        if okP and Core.IsValidObj(actor) then
            return actor
        end
    end
    return nil
end

function StationData.GetPlatformWorldBounds(platform)
    local actor = StationData.GetObjectActor(platform)
    if Core.IsValidObj(actor) then
        local okB, origin, extent = pcall(function()
            return actor:GetActorBounds(false)
        end)
        if okB and origin and extent then
            return {
                cx = origin.X or 0,
                cy = origin.Y or 0,
                cz = origin.Z or 0,
                ex = math.max(extent.X or 600, 100),
                ey = math.max(extent.Y or 600, 100),
                ez = math.max(extent.Z or 300, 100),
                hasActor = true,
            }
        end
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc then
            return { cx = loc.X or 0, cy = loc.Y or 0, cz = loc.Z or 0, ex = 600, ey = 600, ez = 300, hasActor = true }
        end
    end

    local okL, loc = pcall(function() return platform.Location end)
    if okL and loc then
        return { cx = loc.X or 0, cy = loc.Y or 0, cz = loc.Z or 0, ex = 600, ey = 600, ez = 300, hasActor = false }
    end
    return { cx = 0, cy = 0, cz = 0, ex = 600, ey = 600, ez = 300, hasActor = false }
end

function StationData.GetMachineWorldPosAndYaw(machine, fallbackBounds)
    local actor = StationData.GetObjectActor(machine)
    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        local okRot, rot = pcall(function() return actor:K2_GetActorRotation() end)
        if okLoc and loc then
            return loc.X or 0, loc.Y or 0, loc.Z or 0, (okRot and rot and rot.Yaw) or 0
        end
    end

    local okL, loc = pcall(function() return machine.Location end)
    if okL and loc and (loc.X ~= nil) then
        return loc.X or 0, loc.Y or 0, loc.Z or 0, 0
    end

    if fallbackBounds then
        return fallbackBounds.cx, fallbackBounds.cy, fallbackBounds.cz, 0
    end
    return 0, 0, 0, 0
end

-- Clusters station platforms into discrete floors sorted bottom-to-top (1..N).
-- Returns floors = { { index=1, z=..., platforms={ { platform=..., bounds=... }, ... } }, ... },
--         currentFloorIndex (matching walkFrame or playerZ),
--         unitSize (estimated 1x1 module width in Unreal cm).
function StationData.BuildStationFloorMap(station, walkFrame, playerZ)
    local plats = StationData.GetStationPlatforms(station)
    if #plats == 0 and Core.IsValidObj(walkFrame) then
        plats = { walkFrame }
    end

    local entries = {}
    local minHalf = nil
    for _, p in ipairs(plats) do
        local b = StationData.GetPlatformWorldBounds(p)
        table.insert(entries, { platform = p, bounds = b })
        local smaller = math.min(b.ex, b.ey)
        if not minHalf or smaller < minHalf then
            minHalf = smaller
        end
    end

    -- Default 1x1 module size = 2 * minHalf (usually ~1200-2000 cm)
    local unitSize = (minHalf and minHalf > 100) and (minHalf * 2.0) or 1200.0
    local zTolerance = 250.0

    table.sort(entries, function(a, b) return a.bounds.cz < b.bounds.cz end)

    local floors = {}
    for _, entry in ipairs(entries) do
        local placed = false
        for _, fl in ipairs(floors) do
            if math.abs(entry.bounds.cz - fl.z) <= zTolerance then
                table.insert(fl.platforms, entry)
                fl.z = (fl.z * (#fl.platforms - 1) + entry.bounds.cz) / #fl.platforms
                placed = true
                break
            end
        end
        if not placed then
            table.insert(floors, {
                index = #floors + 1,
                z = entry.bounds.cz,
                platforms = { entry },
            })
        end
    end

    local currentFloorIndex = 1
    if Core.IsValidObj(walkFrame) then
        local walkAddr = walkFrame:GetAddress()
        local foundByFrame = false
        for _, fl in ipairs(floors) do
            for _, pe in ipairs(fl.platforms) do
                if pe.platform:GetAddress() == walkAddr then
                    currentFloorIndex = fl.index
                    foundByFrame = true
                    break
                end
            end
            if foundByFrame then break end
        end
        if not foundByFrame and type(playerZ) == "number" and #floors > 0 then
            local bestDist = math.huge
            for _, fl in ipairs(floors) do
                local d = math.abs(playerZ - fl.z)
                if d < bestDist then
                    bestDist = d
                    currentFloorIndex = fl.index
                end
            end
        end
    elseif type(playerZ) == "number" and #floors > 0 then
        local bestDist = math.huge
        for _, fl in ipairs(floors) do
            local d = math.abs(playerZ - fl.z)
            if d < bestDist then
                bestDist = d
                currentFloorIndex = fl.index
            end
        end
    end

    return floors, currentFloorIndex, unitSize
end

--------------------------------------------------------------------------------
-- Machine Classification & Item Icon Extraction
--------------------------------------------------------------------------------

function StationData.GetFrameMachines(frame)
    local out = {}
    if not Core.IsValidObj(frame) then return out end

    local okFind, arr = pcall(function() return frame:FindMachines() end)
    if okFind and arr then
        StationData.ForEachArray(arr, function(_, elem)
            local m = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(m) then
                table.insert(out, m)
            end
        end)
        return out
    end

    local okProp, propArr = pcall(function() return frame.Machines end)
    if okProp and propArr then
        StationData.ForEachArray(propArr, function(_, elem)
            local m = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(m) then
                table.insert(out, m)
            end
        end)
    end
    return out
end

function StationData.GetMachineCategory(machine)
    if not Core.IsValidObj(machine) then return "Other" end

    local asmCls = GetClassCached("AssemblerObject", PATHS.AssemblerObjectClass)
    if Core.IsValidObj(asmCls) and machine:IsA(asmCls) then
        return "Assembler"
    end

    local contCls = GetClassCached("ContainerObject", PATHS.ContainerObjectClass)
    if Core.IsValidObj(contCls) and machine:IsA(contCls) then
        return "Container"
    end

    local convCls = GetClassCached("ConveyorBeltObject", PATHS.ConveyorBeltObjectClass)
    if Core.IsValidObj(convCls) and machine:IsA(convCls) then
        return "Conveyor"
    end

    return "Other"
end

function StationData.GetContainerInventory(container)
    if not Core.IsValidObj(container) then return nil end
    if container.GetInventory then
        local ok, inv = pcall(function() return container:GetInventory() end)
        if ok and Core.IsValidObj(inv) then return inv end
    end
    local okP, invP = pcall(function() return container.Inventory end)
    if okP and Core.IsValidObj(invP) then return invP end
    return nil
end

function StationData.GetPrimaryItemForMachine(machine)
    if not Core.IsValidObj(machine) then return nil, "Other" end
    local cat = StationData.GetMachineCategory(machine)

    if cat == "Assembler" then
        local okRec, rec = pcall(function() return machine.Recipe end)
        if okRec and Core.IsValidObj(rec) then
            local okOut, outStack = pcall(function() return rec.Output end)
            if okOut and outStack and Core.IsValidObj(outStack.Item) then
                return outStack.Item, cat
            end
            local okOuts, outs = pcall(function() return rec:GetOutputs() end)
            if okOuts and outs then
                local firstItem = nil
                StationData.ForEachArray(outs, function(_, elem)
                    if firstItem then return end
                    local st = elem
                    if type(elem.get) == "function" then
                        local okG, g = pcall(function() return elem:get() end)
                        if okG then st = g end
                    end
                    if st and Core.IsValidObj(st.Item) then
                        firstItem = st.Item
                    end
                end)
                if firstItem then return firstItem, cat end
            end
        end
        return nil, cat
    end

    if cat == "Container" then
        local inv = StationData.GetContainerInventory(machine)
        if Core.IsValidObj(inv) then
            local bestItem = nil
            local bestAmount = -1
            local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
            if okSlots and slots then
                StationData.ForEachArray(slots, function(_, elem)
                    local st = elem
                    if type(elem.get) == "function" then
                        local okG, g = pcall(function() return elem:get() end)
                        if okG then st = g end
                    end
                    if st and Core.IsValidObj(st.Item) then
                        local amt = tonumber(st.Amount) or 1
                        if amt > bestAmount then
                            bestAmount = amt
                            bestItem = st.Item
                        end
                    end
                end)
            end
            if bestItem then return bestItem, cat end
        end
        return nil, cat
    end

    if cat == "Conveyor" then
        local okCur, cur = pcall(function() return machine.CurrentItem end)
        if okCur and cur ~= nil then
            local itemCls = GetClassCached("Item", PATHS.ItemClass)
            if Core.IsValidObj(cur) and Core.IsValidObj(itemCls) and cur:IsA(itemCls) then
                return cur, cat
            end
            local okItem, it = pcall(function() return cur.Item end)
            if okItem and Core.IsValidObj(it) then
                return it, cat
            end
        end
        return nil, cat
    end

    return nil, cat
end

function StationData.GetMachineDisplayName(machine)
    if not Core.IsValidObj(machine) then return "Machine" end
    local okB, b = pcall(function() return machine.Buildable end)
    if okB and Core.IsValidObj(b) then
        local okN, n = pcall(function() return b.DisplayName:ToString() end)
        if okN and n and n ~= "" then return n end
    end
    local okCls, cls = pcall(function() return machine:GetClass():GetFName():ToString() end)
    if okCls and cls then
        return cls:gsub("^BP_", ""):gsub("Object_C$", ""):gsub("_C$", "")
    end
    return "Machine"
end

return StationData
