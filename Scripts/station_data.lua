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
    local okLen, len = pcall(function()
        return arr.GetArrayNum and arr:GetArrayNum() or #arr
    end)
    if not okLen or type(len) ~= "number" then
        okLen, len = pcall(function() return #arr end)
    end
    if okLen and type(len) == "number" then
        for i = 1, len do
            local okElem, elem = pcall(function() return arr[i] end)
            if okElem and elem ~= nil then
                fn(i, elem)
            end
        end
        return
    end

    pcall(function()
        arr:ForEach(function(idx, elem)
            fn(idx, elem)
        end)
    end)
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

local CachedPlatforms = { key = nil, time = -999, list = {} }
local CachedMachinesByFrame = {} -- frameAddr -> { time = ..., list = {} }
local CachedPlayersSnapshot = { time = -999, list = {} }

function StationData.GetStationPlatforms(station, fallbackFrame)
    local result = {}
    local refObj = Core.IsValidObj(station) and station or fallbackFrame
    if not Core.IsValidObj(refObj) then return result end

    local now = os.clock()
    local cacheKey = tostring(refObj:GetAddress())
    if CachedPlatforms.key == cacheKey and (now - CachedPlatforms.time) < 3.0 and #CachedPlatforms.list > 0 then
        local validList = {}
        for _, p in ipairs(CachedPlatforms.list) do
            if Core.IsValidObj(p) then table.insert(validList, p) end
        end
        if #validList > 0 then return validList end
    end

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

    if Core.IsValidObj(station) then
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
    end

    -- Resolve target PowerGrid address for reliable station matching
    local targetGridAddr = nil
    if Core.IsValidObj(fallbackFrame) and fallbackFrame.GetStationPowerGrid then
        local okG, g = pcall(function() return fallbackFrame:GetStationPowerGrid() end)
        if okG and Core.IsValidObj(g) then targetGridAddr = g:GetAddress() end
    end
    if not targetGridAddr and Core.IsValidObj(station) and station.GetPowerGrid then
        local okG, g = pcall(function() return station:GetPowerGrid() end)
        if okG and Core.IsValidObj(g) then targetGridAddr = g:GetAddress() end
    end

    -- Fallback: scan live StationPlatformObject instances belonging to this station / power grid
    local okAll, allPlats = pcall(FindAllOf, "StationPlatformObject")
    if okAll and allPlats then
        local stAddr = Core.IsValidObj(station) and station:GetAddress() or nil
        local stId = Core.IsValidObj(station) and StationData.GetObjectKey(station) or nil
        for _, p in ipairs(allPlats) do
            if Core.IsValidObj(p) then
                local belongs = false
                if targetGridAddr and p.GetStationPowerGrid then
                    local okPG, pg = pcall(function() return p:GetStationPowerGrid() end)
                    if okPG and Core.IsValidObj(pg) and pg:GetAddress() == targetGridAddr then
                        belongs = true
                    end
                end
                if not belongs and stAddr then
                    for _, propName in ipairs({ "Station", "ParentStation", "OwnerStation" }) do
                        local okS, sVal = pcall(function() return p[propName] end)
                        if okS and Core.IsValidObj(sVal) and sVal:GetAddress() == stAddr then
                            belongs = true
                            break
                        end
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

    CachedPlatforms = { key = cacheKey, time = now, list = result }
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
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc and type(loc.X) == "number" then
            local cx, cy, cz = loc.X, loc.Y or 0, loc.Z or 0
            local yaw = 0
            local okFwd, fwd = pcall(function() return actor:GetActorForwardVector() end)
            if okFwd and fwd and type(fwd.X) == "number" and type(fwd.Y) == "number" then
                yaw = math.deg(math.atan(fwd.Y, fwd.X))
            else
                local okRot, rot = pcall(function() return actor:K2_GetActorRotation() end)
                if okRot and rot and type(rot.Yaw) == "number" then
                    yaw = rot.Yaw
                end
            end
            local ex, ey = 600.0, 600.0

            -- Measure true module half-extents from ConnectorComponents if present
            local conns = StationData.GetPlatformConnectors(platform)
            if #conns > 0 then
                local rad = math.rad(-yaw)
                local cosA, sinA = math.cos(rad), math.sin(rad)
                local maxLx, maxLy = 0.0, 0.0
                for _, c in ipairs(conns) do
                    local dx, dy = c.x - cx, c.y - cy
                    local lx = math.abs(dx * cosA - dy * sinA)
                    local ly = math.abs(dx * sinA + dy * cosA)
                    if lx > maxLx then maxLx = lx end
                    if ly > maxLy then maxLy = ly end
                end
                if maxLx > 200.0 then ex = maxLx end
                if maxLy > 200.0 then ey = maxLy end
            end

            return { cx = cx, cy = cy, cz = cz, ex = ex, ey = ey, ez = 300, yaw = yaw, hasActor = true }
        end
    end

    local okL, loc = pcall(function() return platform.Location end)
    if okL and loc then
        local x, y, z = Core.GetFPVector(loc)
        return { cx = x, cy = y, cz = z, ex = 600, ey = 600, ez = 300, yaw = 0, hasActor = false }
    end
    return { cx = 0, cy = 0, cz = 0, ex = 600, ey = 600, ez = 300, yaw = 0, hasActor = false }
end

function StationData.GetPlatformConnectors(platform)
    local connectors = {}
    if not Core.IsValidObj(platform) then return connectors end

    local actor = StationData.GetObjectActor(platform)
    if Core.IsValidObj(actor) then
        local okComps, comps = pcall(function() return actor.ConnectorComponents end)
        if okComps and comps then
            StationData.ForEachArray(comps, function(_, elem)
                local comp = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(comp) then
                    local okL, loc = pcall(function() return comp:K2_GetComponentLocation() end)
                    if okL and loc and type(loc.X) == "number" then
                        local occupied = false
                        pcall(function() occupied = comp.bOccupied == true end)
                        table.insert(connectors, { x = loc.X, y = loc.Y or 0, occupied = occupied })
                    end
                end
            end)
        end
    end
    return connectors
end

function StationData.GetMachineWorldPosAndYaw(machine, fallbackBounds)
    local actor = StationData.GetObjectActor(machine)
    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        local okRot, rot = pcall(function() return actor:K2_GetActorRotation() end)
        if okLoc and loc and type(loc.X) == "number" then
            return loc.X, loc.Y or 0, loc.Z or 0, (okRot and rot and type(rot.Yaw) == "number") and rot.Yaw or 0
        end
    end

    local okL, loc = pcall(function() return machine.Location end)
    if okL and loc then
        local x, y, z = Core.GetFPVector(loc)
        return x, y, z, 0
    end

    if fallbackBounds then
        return tonumber(fallbackBounds.cx) or 0, tonumber(fallbackBounds.cy) or 0, tonumber(fallbackBounds.cz) or 0, 0
    end
    return 0, 0, 0, 0
end

-- Clusters station platforms into discrete floors sorted bottom-to-top (1..N).
-- Returns floors = { { index=1, z=..., platforms={ { platform=..., bounds=... }, ... } }, ... },
--         currentFloorIndex (matching walkFrame or playerZ),
--         unitSize (estimated 1x1 module width in Unreal cm).
function StationData.BuildStationFloorMap(station, walkFrame, playerZ)
    local plats = StationData.GetStationPlatforms(station, walkFrame)
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

    local frameAddr = frame:GetAddress()
    local now = os.clock()
    local cached = CachedMachinesByFrame[frameAddr]
    if cached and (now - cached.time) < 2.0 then
        local validList = {}
        for _, m in ipairs(cached.list) do
            if Core.IsValidObj(m) then table.insert(validList, m) end
        end
        return validList
    end

    local okFind, arr = pcall(function() return frame:FindMachines() end)
    if okFind and arr then
        StationData.ForEachArray(arr, function(_, elem)
            local m = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(m) then
                table.insert(out, m)
            end
        end)
        if #out > 0 then return out end
    end

    local okProp, propArr = pcall(function() return frame.Machines end)
    if okProp and propArr then
        StationData.ForEachArray(propArr, function(_, elem)
            local m = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(m) then
                table.insert(out, m)
            end
        end)
        if #out > 0 then return out end
    end

    local okAll, allMachines = pcall(FindAllOf, "MachineObject")
    if okAll and allMachines then
        for _, m in ipairs(allMachines) do
            if Core.IsValidObj(m) and m.GetFrame then
                local okF, mf = pcall(function() return m:GetFrame() end)
                if okF and Core.IsValidObj(mf) and mf:GetAddress() == frameAddr then
                    table.insert(out, m)
                end
            end
        end
    end
    CachedMachinesByFrame[frameAddr] = { time = now, list = out }
    return out
end

function StationData.GetItemIconTexture(item)
    if not Core.IsValidObj(item) then return nil end
    for _, prop in ipairs({ "Icon", "Texture", "IconTexture" }) do
        local ok, tex = pcall(function() return item[prop] end)
        if ok and Core.IsValidObj(tex) then
            return tex
        end
    end
    return nil
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

--------------------------------------------------------------------------------
-- Player Discovery & Online/Offline Status
--------------------------------------------------------------------------------

local function ToLuaString(v)
    if v == nil then return nil end
    if type(v) == "string" then
        return (v ~= "" and not v:match("^FString ") and not v:match("^FText ")) and v or nil
    end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" and s ~= "" and not s:match("^FString ") and not s:match("^FText ") then
        return s
    end
    return nil
end

function StationData.GetAllPlayersInfo(localPC)
    local now = os.clock()
    if (now - CachedPlayersSnapshot.time) < 2.0 and #CachedPlayersSnapshot.list > 0 then
        -- Refresh live positions on cached actors without calling FindAllOf
        for _, p in ipairs(CachedPlayersSnapshot.list) do
            if Core.IsValidObj(p.Actor) then
                local okLoc, loc = pcall(function() return p.Actor:K2_GetActorLocation() end)
                if okLoc and loc and type(loc.X) == "number" then
                    p.X, p.Y, p.Z = loc.X, loc.Y or 0, loc.Z or 0
                    p.HasPos = true
                end
            end
        end
        return CachedPlayersSnapshot.list
    end

    local players = {}
    local pc = localPC or Core.GetLocalPlayerController()
    local localPlayerObj = Core.IsValidObj(pc) and pc.PlayerObject or nil
    local localAddr = Core.IsValidObj(localPlayerObj) and localPlayerObj:GetAddress() or nil

    -- Build ConnectedPlayer lookup for nicknames & online status
    local connectedByPlayerAddr = {}
    local connectedById = {}
    local okConn, connList = pcall(FindAllOf, "ConnectedPlayer")
    if okConn and connList then
        for _, cp in ipairs(connList) do
            if Core.IsValidObj(cp) then
                local cpName = nil
                for _, prop in ipairs({ "Nickname", "AccountNickname", "PlayerName", "DisplayName" }) do
                    local okN, n = pcall(function()
                        local v = cp[prop]
                        return (v and type(v.ToString) == "function") and v:ToString() or tostring(v)
                    end)
                    if okN and n and n ~= "" and n ~= "nil" then
                        cpName = n
                        break
                    end
                end
                local po = nil
                pcall(function() po = cp.PlayerObject end)
                if Core.IsValidObj(po) then
                    connectedByPlayerAddr[po:GetAddress()] = { Name = cpName, Connected = cp }
                end
                local pid = nil
                pcall(function() pid = cp.PlayerID or cp.UserID or cp.ID end)
                if pid ~= nil then
                    connectedById[tostring(pid)] = { Name = cpName, Connected = cp }
                end
            end
        end
    end

    local okPO, poList = pcall(FindAllOf, "DMSPlayerObject")
    if not okPO or not poList then return players end

    for _, po in ipairs(poList) do
        if Core.IsValidObj(po) then
            local addr = po:GetAddress()
            local isLocal = (localAddr ~= nil and addr == localAddr)
            local connInfo = connectedByPlayerAddr[addr]
            if not connInfo then
                local okUid, uid = pcall(function() return po.UserID or po.ID end)
                if okUid and uid ~= nil then
                    connInfo = connectedById[tostring(uid)]
                end
            end

            -- Determine online status
            local isOnline = isLocal or (connInfo ~= nil)
            if not isOnline then
                for _, prop in ipairs({ "bIsOnline", "bOnline", "bConnected", "bIsConnected" }) do
                    local okB, bVal = pcall(function() return po[prop] end)
                    if okB and type(bVal) == "boolean" then
                        isOnline = bVal
                        break
                    end
                end
            end
            if not isOnline then
                local okCtrl, ctrl = pcall(function() return po.Controller or po.PlayerController end)
                if okCtrl and Core.IsValidObj(ctrl) then
                    isOnline = true
                end
            end

            -- Resolve nickname
            local name = connInfo and ToLuaString(connInfo.Name) or nil
            if (not name or name == "") and isLocal and Core.IsValidObj(pc) then
                local okAcc, acc = pcall(function() return pc:GetAccountNickname() end)
                if okAcc and acc then
                    name = ToLuaString(acc)
                end
            end
            if not name or name == "" then
                for _, prop in ipairs({ "DisplayName", "PlayerName", "Nickname", "AccountNickname" }) do
                    local okN, v = pcall(function() return po[prop] end)
                    if okN and v ~= nil then
                        local s = ToLuaString(v)
                        if s then
                            name = s
                            break
                        end
                    end
                end
            end
            if not name or name == "" then
                name = isLocal and "You" or "Player"
            end

            -- Resolve world position & actor
            local actor = StationData.GetObjectActor(po)
            if not Core.IsValidObj(actor) and isLocal and Core.IsValidObj(pc) then
                local okPawn, pawn = pcall(function() return pc.Pawn end)
                if okPawn and Core.IsValidObj(pawn) then actor = pawn end
            end
            if not Core.IsValidObj(actor) then
                pcall(function() actor = po.Character or po.Pawn end)
            end
            local px, py, pz = 0, 0, 0
            local hasPos = false
            if Core.IsValidObj(actor) then
                local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
                if okLoc and loc then
                    px, py, pz = loc.X or 0, loc.Y or 0, loc.Z or 0
                    hasPos = true
                end
            elseif Core.IsValidObj(po.PilotedShip) then
                local shipActor = StationData.GetObjectActor(po.PilotedShip)
                if Core.IsValidObj(shipActor) then
                    local okLoc, loc = pcall(function() return shipActor:K2_GetActorLocation() end)
                    if okLoc and loc then
                        px, py, pz = loc.X or 0, loc.Y or 0, loc.Z or 0
                        hasPos = true
                    end
                end
            end
            if not hasPos then
                local okL, loc = pcall(function() return po.Location end)
                if okL and loc and loc.X ~= nil then
                    px, py, pz = loc.X or 0, loc.Y or 0, loc.Z or 0
                    hasPos = true
                end
            end

            local frame = nil
            pcall(function() frame = po:GetFrame() end)

            table.insert(players, {
                Key = StationData.GetObjectKey(po) or tostring(addr),
                PlayerObject = po,
                Actor = actor,
                Name = name,
                IsLocal = isLocal,
                IsOnline = isOnline,
                X = px,
                Y = py,
                Z = pz,
                HasPos = hasPos,
                Frame = frame,
                PilotedShip = po.PilotedShip,
            })
        end
    end

    CachedPlayersSnapshot = { time = now, list = players }
    return players
end

return StationData
