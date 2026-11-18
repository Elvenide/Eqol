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
local CachedFootprintsByClass = {} -- clsAddr -> { cellsX = n, cellsY = n }

local StationDiagLoggedKey = nil

local function ReadBoundsStruct(boundsObj)
    if not boundsObj then return nil end
    local unwrapped = Core.UnwrapStruct(boundsObj)
    if not unwrapped then return nil end

    -- Case 1: FBox / FFixedBox with Min / Max (float or fixed-point)
    local okMinMax, minV, maxV = pcall(function() return unwrapped.Min, unwrapped.Max end)
    if okMinMax and minV and maxV then
        local x1, y1, z1 = Core.GetFPVector(minV)
        local x2, y2, z2 = Core.GetFPVector(maxV)
        local dx, dy = math.abs(x2 - x1), math.abs(y2 - y1)
        if dx >= 50.0 or dy >= 50.0 then
            return {
                cx = (x1 + x2) * 0.5,
                cy = (y1 + y2) * 0.5,
                cz = (z1 + z2) * 0.5,
                ex = dx * 0.5,
                ey = dy * 0.5,
                ez = math.abs(z2 - z1) * 0.5,
            }
        end
    end

    -- Case 2: FBoxSphereBounds with Origin / BoxExtent
    local okOrig, origV, extV = pcall(function() return unwrapped.Origin, unwrapped.BoxExtent end)
    if okOrig and origV and extV then
        local ox, oy, oz = Core.GetFPVector(origV)
        local ex, ey, ez = Core.GetFPVector(extV)
        if math.abs(ex) >= 50.0 or math.abs(ey) >= 50.0 then
            return { cx = ox, cy = oy, cz = oz, ex = math.abs(ex), ey = math.abs(ey), ez = math.max(50.0, math.abs(ez)) }
        end
    end

    -- Case 3: Center / Extent struct variants
    local okCE, cenV, cenExtV = pcall(function()
        return unwrapped.Center or unwrapped.Location, unwrapped.Extent or unwrapped.Extents or unwrapped.Size
    end)
    if okCE and cenV and cenExtV then
        local ox, oy, oz = Core.GetFPVector(cenV)
        local ex, ey, ez = Core.GetFPVector(cenExtV)
        if math.abs(ex) >= 50.0 or math.abs(ey) >= 50.0 then
            return { cx = ox, cy = oy, cz = oz, ex = math.abs(ex), ey = math.abs(ey), ez = math.max(50.0, math.abs(ez)) }
        end
    end

    return nil
end

local function InspectStructFieldNames(objOrStruct, maxFields)
    local names = {}
    if not objOrStruct then return "nil" end
    local unwrapped = Core.UnwrapStruct(objOrStruct)
    if not unwrapped then return "nil" end
    pcall(function()
        local cls = unwrapped.GetClass and unwrapped:GetClass() or (unwrapped.GetStruct and unwrapped:GetStruct())
        local target = Core.IsValidObj(cls) and cls or unwrapped
        if target and target.ForEachProperty then
            target:ForEachProperty(function(prop)
                if #names < (maxFields or 18) then
                    local pn = nil
                    pcall(function() pn = prop:GetFName():ToString() end)
                    if pn then table.insert(names, pn) end
                end
            end)
        end
    end)
    if #names == 0 then return "?" end
    return table.concat(names, ",")
end

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
                    local u = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(u) then
                        addPlat(u)
                    else
                        local st = Core.UnwrapStruct(elem)
                        if st then
                            for _, fName in ipairs({ "Platform", "PlatformObject", "Object", "Actor", "Frame" }) do
                                local okF, fObj = pcall(function() return st[fName] end)
                                if okF and Core.IsValidObj(fObj) then
                                    addPlat(fObj)
                                    break
                                end
                            end
                        end
                    end
                end)
            end
        end

        -- Also resolve station.PlatformIDs through DMSWorldSubsystem:GetObject(id)
        local okPids, pids = pcall(function() return station.PlatformIDs end)
        if okPids and pids then
            local worldSub = Core.GetWorldSubsystem(Core.GetLocalPlayerController(), Core.PATHS.WorldSubsystemClass)
            if Core.IsValidObj(worldSub) and worldSub.GetObject then
                StationData.ForEachArray(pids, function(_, elem)
                    local rawId = elem
                    pcall(function() if type(elem.get) == "function" then rawId = elem:get() end end)
                    if rawId ~= nil then
                        local okObj, obj = pcall(function() return worldSub:GetObject(rawId) end)
                        if okObj and Core.IsValidObj(obj) then
                            addPlat(obj)
                        end
                    end
                end)
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

    -- Scan live StationPlatform / StationPlatformObject instances belonging to this station
    local okAllSt, allStations = pcall(FindAllOf, "StationObject")
    local singleStationInWorld = (okAllSt and allStations and #allStations <= 1)

    for _, searchCls in ipairs({ "StationPlatformObject", "StationPlatform" }) do
        local okAll, allPlats = pcall(FindAllOf, searchCls)
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
                        for _, propName in ipairs({ "Station", "ParentStation", "OwnerStation", "OwningStation", "Parent", "ParentFrame" }) do
                            local okS, sVal = pcall(function() return p[propName] end)
                            if okS and Core.IsValidObj(sVal) and sVal:GetAddress() == stAddr then
                                belongs = true
                                break
                            end
                        end
                        if not belongs then
                            for _, fnName in ipairs({ "GetStation", "GetFrame", "GetParentFrame" }) do
                                if p[fnName] then
                                    local okF, fVal = pcall(function() return p[fnName](p) end)
                                    if okF and Core.IsValidObj(fVal) and fVal:GetAddress() == stAddr then
                                        belongs = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                    if not belongs and stId then
                        local okPid, pid = pcall(function() return p.ParentID or p.StationID end)
                        if okPid and pid ~= nil and tostring(pid) == stId then
                            belongs = true
                        end
                    end
                    if not belongs and singleStationInWorld then
                        belongs = true
                    end
                    if belongs then
                        addPlat(p)
                    end
                end
            end
        end
    end

    if #result > 0 then
        CachedPlatforms = { key = cacheKey, time = now, list = result }
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

function StationData.GetPlatformWorldBounds(platform, station, platIndex1)
    local cx, cy, cz = nil, nil, nil
    local yaw = 0
    local ex, ey, ez = nil, nil, nil
    local hasActor = false

    local platId = nil
    pcall(function()
        if platform and platform.ID ~= nil then
            platId = tonumber(platform.ID)
        end
    end)

    local actor = StationData.GetObjectActor(platform)
    if not Core.IsValidObj(actor) and Core.IsValidObj(platform) then
        -- Check if platform itself is already an AActor
        pcall(function()
            if platform.K2_GetActorLocation then actor = platform end
        end)
    end

    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc and type(loc.X) == "number" then
            cx, cy, cz = loc.X, loc.Y or 0, loc.Z or 0
            hasActor = true
            local okFwd, fwd = pcall(function() return actor:GetActorForwardVector() end)
            if okFwd and fwd and type(fwd.X) == "number" and type(fwd.Y) == "number" then
                yaw = math.deg(math.atan(fwd.Y, fwd.X))
            else
                local okRot, rot = pcall(function() return actor:K2_GetActorRotation() end)
                if okRot and rot and type(rot.Yaw) == "number" then
                    yaw = rot.Yaw
                end
            end

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

            -- Also measure StaticMeshComponents on platform actor if connectors didn't give extents
            if not ex or not ey then
                pcall(function()
                    local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
                    if Core.IsValidObj(smCls) and actor.K2_GetComponentsByClass then
                        local compsRaw = actor:K2_GetComponentsByClass(smCls)
                        local maxEx, maxEy = 0.0, 0.0
                        StationData.ForEachArray(compsRaw, function(_, elem)
                            local c = Core.UnwrapArrayElem(elem)
                            if Core.IsValidObj(c) and c.StaticMesh and c.StaticMesh.ExtendedBounds then
                                local eb = c.StaticMesh.ExtendedBounds
                                if eb.BoxExtent then
                                    local rs = c.RelativeScale3D
                                    local sx = rs and (tonumber(rs.X) or 1.0) or 1.0
                                    local sy = rs and (tonumber(rs.Y) or 1.0) or 1.0
                                    local bx = math.abs((tonumber(eb.BoxExtent.X) or 0.0) * sx)
                                    local by = math.abs((tonumber(eb.BoxExtent.Y) or 0.0) * sy)
                                    if bx > maxEx then maxEx = bx end
                                    if by > maxEy then maxEy = by end
                                end
                            end
                        end)
                        if maxEx >= 400.0 then ex = math.floor(maxEx / 50.0 + 0.5) * 50.0 end
                        if maxEy >= 400.0 then ey = math.floor(maxEy / 50.0 + 0.5) * 50.0 end
                    end
                end)
            end
        end
    end

    -- Check direct Bounds struct on platform or station.PlatformBounds[platIndex1]
    local boundsInfo = nil
    pcall(function()
        if platform and platform.Bounds then
            boundsInfo = ReadBoundsStruct(platform.Bounds)
        end
    end)
    if not boundsInfo and Core.IsValidObj(station) and type(platIndex1) == "number" then
        pcall(function()
            local pbArr = station.PlatformBounds
            if pbArr and pbArr[platIndex1] then
                boundsInfo = ReadBoundsStruct(pbArr[platIndex1])
            end
        end)
    end
    if boundsInfo then
        if not cx then cx, cy, cz = boundsInfo.cx, boundsInfo.cy, boundsInfo.cz end
        if (not ex or ex < 200.0) and boundsInfo.ex >= 200.0 then ex = boundsInfo.ex end
        if (not ey or ey < 200.0) and boundsInfo.ey >= 200.0 then ey = boundsInfo.ey end
        if not ez and boundsInfo.ez > 50.0 then ez = boundsInfo.ez end
    end

    -- Check platform.Location (fixed-point vector, potentially relative to station)
    if not cx and Core.IsValidObj(platform) then
        local okL, loc = pcall(function() return platform.Location end)
        if okL and loc then
            local x, y, z = Core.GetFPVector(loc)
            if Core.IsValidObj(station) and station:GetAddress() ~= platform:GetAddress() then
                local stActor = StationData.GetObjectActor(station)
                if Core.IsValidObj(stActor) then
                    local okSL, sl = pcall(function() return stActor:K2_GetActorLocation() end)
                    if okSL and sl and type(sl.X) == "number" then
                        -- Check whether platform.Location looks station-local vs world
                        if math.abs(x - sl.X) > 200000.0 or math.abs(y - sl.Y) > 200000.0 then
                            x = sl.X + x
                            y = sl.Y + y
                            z = (sl.Z or 0) + z
                        end
                    end
                end
            end
            cx, cy, cz = x, y, z
        end
    end

    -- Check platform.Dimensions / platform.Size (e.g. grid size or cm)
    if (not ex or not ey) and Core.IsValidObj(platform) then
        pcall(function()
            for _, dimProp in ipairs({ "Dimensions", "Size", "PlatformDimensions", "GridSize" }) do
                local d = platform[dimProp]
                if d and d.X and d.Y then
                    local dx, dy = math.abs(tonumber(d.X) or 0), math.abs(tonumber(d.Y) or 0)
                    if dx > 0 and dy > 0 then
                        if dx < 100 then dx = dx * 100.0 end
                        if dy < 100 then dy = dy * 100.0 end
                        if not ex then ex = dx * 0.5 end
                        if not ey then ey = dy * 0.5 end
                        break
                    end
                end
            end
        end)
    end

    return {
        cx = cx or 0.0,
        cy = cy or 0.0,
        cz = cz or 0.0,
        ex = ex or 600.0,
        ey = ey or 600.0,
        ez = ez or 300.0,
        yaw = yaw,
        id = platId,
        hasActor = hasActor,
    }
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
-- Returns floors = { { index=1, z=..., platforms={ { platform=..., bounds=... }, ... }, machines={ ... } }, ... },
--         currentFloorIndex (matching walkFrame or playerZ),
--         unitSize (estimated 1x1 module width in Unreal cm),
--         gridOriginX, gridOriginY (100cm grid alignment from first module edge).
local function CollectExtraStationZLevels(station, allMachines, stationRefZ)
    local zPts = {}
    local seen = {}
    local function pushZ(z)
        if type(z) ~= "number" then return end
        if stationRefZ and math.abs(z) < 1.0 and math.abs(stationRefZ) > 500.0 then
            return -- Ignore unspawned/default Z=0 machines when station itself is deep in space
        end
        for _, ez in ipairs(seen) do
            if math.abs(z - ez) <= 220.0 then return end
        end
        table.insert(seen, z)
        table.insert(zPts, z)
    end

    -- 1. Elevators belonging ONLY to THIS station (via station.Elevators -> ElevatorStack)
    if Core.IsValidObj(station) then
        pcall(function()
            local elevs = station.Elevators
            if elevs then
                StationData.ForEachArray(elevs, function(_, eElem)
                    local el = Core.UnwrapArrayElem(eElem)
                    if Core.IsValidObj(el) and el.ElevatorStack then
                        StationData.ForEachArray(el.ElevatorStack, function(_, elem)
                            local stopObj = Core.UnwrapArrayElem(elem)
                            if Core.IsValidObj(stopObj) and stopObj.bIsElevatorStop == true then
                                local _, _, sz = StationData.GetMachineWorldPosAndYaw(stopObj)
                                pushZ(sz)
                            end
                        end)
                    end
                end)
            end
        end)
    end

    -- 2. Machine Z coordinates cover any floor that has machines on this station
    for _, m in ipairs(allMachines) do
        local _, _, mz = StationData.GetMachineWorldPosAndYaw(m)
        pushZ(mz)
    end

    return zPts
end

function StationData.BuildStationFloorMap(station, walkFrame, playerZ)
    local plats = StationData.GetStationPlatforms(station, walkFrame)
    if #plats == 0 and Core.IsValidObj(walkFrame) then
        plats = { walkFrame }
    end

    local entries = {}
    local seenBoundSig = {}
    local minHalf = nil
    for idx1, p in ipairs(plats) do
        local b = StationData.GetPlatformWorldBounds(p, station, idx1)
        table.insert(entries, { platform = p, bounds = b })
        seenBoundSig[string.format("%.0f:%.0f:%.0f", b.cx, b.cy, b.cz)] = true
        local smaller = math.min(b.ex, b.ey)
        if not minHalf or smaller < minHalf then
            minHalf = smaller
        end
    end

    -- Also ingest any station.PlatformBounds entries not already represented by a platform object
    local pbCount = 0
    if Core.IsValidObj(station) then
        pcall(function()
            local pbArr = station.PlatformBounds
            if pbArr then
                StationData.ForEachArray(pbArr, function(idx1, elem)
                    pbCount = pbCount + 1
                    local b = ReadBoundsStruct(elem)
                    if b then
                        local sig = string.format("%.0f:%.0f:%.0f", b.cx, b.cy, b.cz)
                        if not seenBoundSig[sig] then
                            seenBoundSig[sig] = true
                            local matchPlat = plats[idx1] or plats[1] or station
                            table.insert(entries, { platform = matchPlat, bounds = b })
                            local smaller = math.min(b.ex, b.ey)
                            if not minHalf or smaller < minHalf then minHalf = smaller end
                        end
                    end
                end)
            end
        end)
    end

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
                machines = {},
            })
        end
    end

    -- Collect all station machines (owned by station / walkFrame / platforms)
    local allMachines = StationData.GetAllStationMachines(station, plats, walkFrame)

    -- Discover any missing Z floors from THIS station's Elevators & machine Z coordinates
    local stRefZ = nil
    local stAct = Core.IsValidObj(station) and StationData.GetObjectActor(station) or nil
    if Core.IsValidObj(stAct) then
        pcall(function()
            local l = stAct:K2_GetActorLocation()
            if l and type(l.Z) == "number" then stRefZ = l.Z end
        end)
    end
    local extraZs = CollectExtraStationZLevels(station, allMachines, stRefZ)
    -- If existing single fallback floor was only at default cz=0 with no real actor bounds, replace/augment cleanly
    if #floors == 1 and not (entries[1] and entries[1].bounds and entries[1].bounds.hasActor) and #extraZs > 0 then
        local onlyDefault = (math.abs(floors[1].z) < 1.0)
        if onlyDefault then
            local nearZero = false
            for _, ez in ipairs(extraZs) do
                if math.abs(ez - floors[1].z) <= zTolerance then nearZero = true break end
            end
            if not nearZero then
                floors = {}
            end
        end
    end

    local fallbackPlat = entries[1] and entries[1].platform or walkFrame or station
    local templateBoundsList = {}
    for _, e in ipairs(entries) do
        table.insert(templateBoundsList, e.bounds)
    end
    if #templateBoundsList == 0 then
        table.insert(templateBoundsList, { cx = 0, cy = 0, cz = 0, ex = 600, ey = 600, ez = 300, yaw = 0 })
    end

    for _, ez in ipairs(extraZs) do
        local foundFl = nil
        for _, fl in ipairs(floors) do
            if math.abs(ez - fl.z) <= zTolerance then
                foundFl = fl
                break
            end
        end
        if not foundFl then
            local synthPlats = {}
            for _, tb in ipairs(templateBoundsList) do
                table.insert(synthPlats, {
                    platform = fallbackPlat,
                    bounds = {
                        cx = tb.cx, cy = tb.cy, cz = ez,
                        ex = tb.ex, ey = tb.ey, ez = tb.ez or 300.0,
                        yaw = tb.yaw or 0.0,
                        synthetic = true,
                    },
                })
            end
            table.insert(floors, {
                index = #floors + 1,
                z = ez,
                platforms = synthPlats,
                machines = {},
            })
        end
    end

    -- Sort floors strictly bottom-to-top and re-index 1..N
    table.sort(floors, function(a, b) return a.z < b.z end)
    for i, fl in ipairs(floors) do
        fl.index = i
    end

    -- Bin machines onto their nearest floor by Z
    local stationFallback = entries[1] and entries[1].bounds or nil
    for _, m in ipairs(allMachines) do
        local mx, my, mz, myaw = StationData.GetMachineWorldPosAndYaw(m, stationFallback)
        local bestFl = nil
        local bestDz = math.huge
        for _, fl in ipairs(floors) do
            local dz = math.abs(mz - fl.z)
            if dz < bestDz then
                bestDz = dz
                bestFl = fl
            end
        end
        if bestFl then
            table.insert(bestFl.machines, {
                machine = m,
                x = mx,
                y = my,
                z = mz,
                yaw = myaw,
            })
        end
    end

    -- For synthetic floor outlines, expand/align to contain that floor's machines cleanly if needed
    for _, fl in ipairs(floors) do
        local hasSynth = false
        for _, pe in ipairs(fl.platforms) do
            if pe.bounds.synthetic then hasSynth = true break end
        end
        if hasSynth and #fl.machines > 0 then
            local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
            for _, me in ipairs(fl.machines) do
                if me.x < minX then minX = me.x end
                if me.x > maxX then maxX = me.x end
                if me.y < minY then minY = me.y end
                if me.y > maxY then maxY = me.y end
            end
            local cx = math.floor(((minX + maxX) * 0.5) / 100.0 + 0.5) * 100.0
            local cy = math.floor(((minY + maxY) * 0.5) / 100.0 + 0.5) * 100.0
            local ex = math.max(600.0, math.ceil(((maxX - minX) * 0.5 + 300.0) / 100.0) * 100.0)
            local ey = math.max(600.0, math.ceil(((maxY - minY) * 0.5 + 300.0) / 100.0) * 100.0)
            for _, pe in ipairs(fl.platforms) do
                if pe.bounds.synthetic then
                    pe.bounds.cx, pe.bounds.cy, pe.bounds.ex, pe.bounds.ey = cx, cy, ex, ey
                end
            end
        end
    end

    -- Compute 100cm grid alignment origin from first module's corner edge
    local gridOriginX, gridOriginY = 0.0, 0.0
    local firstB = floors[1] and floors[1].platforms[1] and floors[1].platforms[1].bounds
    if firstB then
        gridOriginX = firstB.cx - firstB.ex
        gridOriginY = firstB.cy - firstB.ey
    end

    -- Determine player's active floor (prefer playerZ if floors differ by Z)
    local currentFloorIndex = 1
    if type(playerZ) == "number" and #floors > 0 then
        local bestDist = math.huge
        for _, fl in ipairs(floors) do
            local d = math.abs(playerZ - fl.z)
            if d < bestDist then
                bestDist = d
                currentFloorIndex = fl.index
            end
        end
    elseif Core.IsValidObj(walkFrame) then
        local walkAddr = walkFrame:GetAddress()
        for _, fl in ipairs(floors) do
            for _, pe in ipairs(fl.platforms) do
                if Core.IsValidObj(pe.platform) and pe.platform:GetAddress() == walkAddr then
                    currentFloorIndex = fl.index
                    break
                end
            end
        end
    end

    -- One-shot runtime diagnostic per station so we can inspect exact BuildingBlocks/Elevators/Station structure
    local diagKey = Core.IsValidObj(station) and tostring(station:GetAddress()) or "none"
    if StationDiagLoggedKey ~= diagKey then
        StationDiagLoggedKey = diagKey
        local wfCls = Core.IsValidObj(walkFrame) and (walkFrame:GetClass():GetFName():ToString()) or "nil"
        local stCls = Core.IsValidObj(station) and (station:GetClass():GetFName():ToString()) or "nil"
        local stLocStr = "noActor"
        if Core.IsValidObj(stAct) then
            pcall(function()
                local l = stAct:K2_GetActorLocation()
                local r = stAct:K2_GetActorRotation()
                stLocStr = string.format("%s@(%.0f,%.0f,%.0f rot=%.1f,%.1f,%.1f)",
                    stAct:GetClass():GetFName():ToString(), l.X or 0, l.Y or 0, l.Z or 0, r.Pitch or 0, r.Yaw or 0, r.Roll or 0)
            end)
        end
        local function ArrCountAndFirst(obj, prop)
            local n, first = 0, "nil"
            pcall(function()
                local arr = obj[prop]
                if arr then
                    StationData.ForEachArray(arr, function(idx, el)
                        n = n + 1
                        if idx == 1 then
                            local u = Core.UnwrapArrayElem(el)
                            if Core.IsValidObj(u) then
                                local c = u:GetClass():GetFName():ToString()
                                local ux, uy, uz = StationData.GetMachineWorldPosAndYaw(u)
                                first = string.format("%s@(%.0f,%.0f,%.0f)", c, ux, uy, uz)
                            else
                                first = "struct[" .. InspectStructFieldNames(el, 8) .. "]"
                            end
                        end
                    end)
                end
            end)
            return n, first
        end
        local bbN, bb1 = ArrCountAndFirst(station, "BuildingBlocks")
        local elN, el1 = ArrCountAndFirst(station, "Elevators")
        local piN, pi1 = ArrCountAndFirst(station, "PlatformIDs")
        local coN, co1 = ArrCountAndFirst(station, "ConstructionObjects")
        local scN, sc1 = ArrCountAndFirst(station, "StationConnections")
        local vcN, vc1 = ArrCountAndFirst(station, "VerticalConnections")
        local mN, m1 = ArrCountAndFirst(station, "Machines")
        local e1b = entries[1] and entries[1].bounds
        local bStr = e1b and string.format("cx=%.0f,cy=%.0f,cz=%.0f,ex=%.0f,ey=%.0f,hasA=%s", e1b.cx, e1b.cy, e1b.cz, e1b.ex, e1b.ey, tostring(e1b.hasActor)) or "nil"
        local flParts = {}
        for _, fl in ipairs(floors) do
            local sample = fl.machines[1] and Core.IsValidObj(fl.machines[1].machine) and fl.machines[1].machine:GetClass():GetFName():ToString() or "-"
            table.insert(flParts, string.format("#%d(z=%.0f,m=%d,%s)", fl.index, fl.z, #fl.machines, sample))
        end
        Core.Log(string.format(
            "[StationData] Diag wf=%s st=%s stActor=%s pz=%s curFl=%d e1=[%s] BB=%d(%s) Elev=%d(%s) PID=%d(%s) CO=%d(%s) SC=%d VC=%d Mach=%d(%s)",
            wfCls, stCls, stLocStr, tostring(playerZ), currentFloorIndex, bStr, bbN, bb1, elN, el1, piN, pi1, coN, co1, scN, vcN, mN, m1
        ))
        Core.Log(string.format("[StationData] Floors(%d): %s", #floors, table.concat(flParts, ", ")))
    end

    return floors, currentFloorIndex, unitSize, gridOriginX, gridOriginY
end

--------------------------------------------------------------------------------
-- Machine Classification & Item Icon Extraction
--------------------------------------------------------------------------------

local function CollectMachinesFromContainer(container, out, seen)
    if not Core.IsValidObj(container) then return end
    local okFind, arr = pcall(function() return container:FindMachines() end)
    if okFind and arr then
        StationData.ForEachArray(arr, function(_, elem)
            local m = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(m) then
                local addr = m:GetAddress()
                if not seen[addr] then
                    seen[addr] = true
                    table.insert(out, m)
                end
            end
        end)
    end
    for _, propName in ipairs({ "Machines", "Elevators", "MultiblockMachines" }) do
        local okProp, propArr = pcall(function() return container[propName] end)
        if okProp and propArr then
            StationData.ForEachArray(propArr, function(_, elem)
                local m = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(m) then
                    local addr = m:GetAddress()
                    if not seen[addr] then
                        seen[addr] = true
                        table.insert(out, m)
                    end
                end
            end)
        end
    end
end

function StationData.GetAllStationMachines(station, platforms, walkFrame)
    local out = {}
    local seen = {}
    local matchFrames = {}

    if Core.IsValidObj(station) then
        matchFrames[station:GetAddress()] = true
        CollectMachinesFromContainer(station, out, seen)
    end
    if Core.IsValidObj(walkFrame) then
        matchFrames[walkFrame:GetAddress()] = true
        CollectMachinesFromContainer(walkFrame, out, seen)
    end
    if platforms then
        for _, p in ipairs(platforms) do
            if Core.IsValidObj(p) then
                matchFrames[p:GetAddress()] = true
                CollectMachinesFromContainer(p, out, seen)
            end
        end
    end

    if #out == 0 and next(matchFrames) ~= nil then
        local okAll, allMachines = pcall(FindAllOf, "MachineObject")
        if okAll and allMachines then
            for _, m in ipairs(allMachines) do
                if Core.IsValidObj(m) and m.GetFrame then
                    local okF, mf = pcall(function() return m:GetFrame() end)
                    if okF and Core.IsValidObj(mf) and matchFrames[mf:GetAddress()] then
                        local addr = m:GetAddress()
                        if not seen[addr] then
                            seen[addr] = true
                            table.insert(out, m)
                        end
                    end
                end
            end
        end
    end

    return out
end

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

    local seen = {}
    CollectMachinesFromContainer(frame, out, seen)
    if #out > 0 then
        CachedMachinesByFrame[frameAddr] = { time = now, list = out }
        return out
    end

    local okAll, allMachines = pcall(FindAllOf, "MachineObject")
    if okAll and allMachines then
        for _, m in ipairs(allMachines) do
            if Core.IsValidObj(m) and m.GetFrame then
                local okF, mf = pcall(function() return m:GetFrame() end)
                if okF and Core.IsValidObj(mf) and mf:GetAddress() == frameAddr then
                    local addr = m:GetAddress()
                    if not seen[addr] then
                        seen[addr] = true
                        table.insert(out, m)
                    end
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
                    local st = Core.UnwrapStruct(elem)
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
                    local st = Core.UnwrapStruct(elem)
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

-- Returns unrotated footprint in 100cm grid cells (cellsX, cellsY) for a machine or buildable.
function StationData.GetMachineFootprintCells(machine, buildableOpt)
    local bld = Core.IsValidObj(buildableOpt) and buildableOpt or nil
    if not bld and Core.IsValidObj(machine) then
        pcall(function() bld = machine.Buildable end)
    end

    local clsKey = nil
    local actor = Core.IsValidObj(machine) and StationData.GetObjectActor(machine) or nil
    if Core.IsValidObj(actor) then
        local okC, cls = pcall(function() return actor:GetClass() end)
        if okC and Core.IsValidObj(cls) then clsKey = cls:GetAddress() end
    elseif Core.IsValidObj(bld) then
        clsKey = bld:GetAddress()
    elseif Core.IsValidObj(machine) then
        local okC, cls = pcall(function() return machine:GetClass() end)
        if okC and Core.IsValidObj(cls) then clsKey = cls:GetAddress() end
    end

    if clsKey and CachedFootprintsByClass[clsKey] then
        local f = CachedFootprintsByClass[clsKey]
        return f.cellsX, f.cellsY
    end

    local cx, cy = nil, nil
    local function tryReadDims(obj)
        if not Core.IsValidObj(obj) then return false end
        local found = false
        pcall(function()
            for _, propName in ipairs({ "MachineDimensions", "Dimensions", "Size" }) do
                local d = obj[propName]
                if d and d.X and d.Y then
                    local dx = math.abs(tonumber(d.X) or 0)
                    local dy = math.abs(tonumber(d.Y) or 0)
                    if dx > 0 and dy > 0 then
                        if dx >= 50 then dx = math.max(1, math.floor(dx / 100.0 + 0.5)) end
                        if dy >= 50 then dy = math.max(1, math.floor(dy / 100.0 + 0.5)) end
                        cx, cy = math.max(1, math.floor(dx + 0.5)), math.max(1, math.floor(dy + 0.5))
                        found = true
                        return
                    end
                end
            end
        end)
        return found
    end

    if not tryReadDims(machine) and not tryReadDims(bld) and Core.IsValidObj(actor) then
        pcall(function()
            local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
            if Core.IsValidObj(smCls) and actor.K2_GetComponentsByClass then
                local compsRaw = actor:K2_GetComponentsByClass(smCls)
                local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
                local any = false
                StationData.ForEachArray(compsRaw, function(_, elem)
                    local c = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(c) and c.StaticMesh and c.StaticMesh.ExtendedBounds then
                        local hidden = (c.bHiddenInGame == true)
                        local okVis, vis = pcall(function() return c:IsVisible() end)
                        local smName = ""
                        pcall(function() smName = c.StaticMesh:GetFName():ToString() end)
                        if not hidden and (not okVis or vis ~= false) and not smName:find("Collision", 1, true) then
                            local eb = c.StaticMesh.ExtendedBounds
                            if eb.BoxExtent and eb.Origin then
                                local rs = c.RelativeScale3D
                                local rl = c.RelativeLocation
                                local sx = math.abs(rs and (tonumber(rs.X) or 1.0) or 1.0)
                                local sy = math.abs(rs and (tonumber(rs.Y) or 1.0) or 1.0)
                                local lx = rl and (tonumber(rl.X) or 0.0) or 0.0
                                local ly = rl and (tonumber(rl.Y) or 0.0) or 0.0
                                local ox = (tonumber(eb.Origin.X) or 0.0) * sx + lx
                                local oy = (tonumber(eb.Origin.Y) or 0.0) * sy + ly
                                local ex = math.abs(tonumber(eb.BoxExtent.X) or 0.0) * sx
                                local ey = math.abs(tonumber(eb.BoxExtent.Y) or 0.0) * sy
                                if ex > 5.0 and ey > 5.0 then
                                    any = true
                                    if ox - ex < minX then minX = ox - ex end
                                    if ox + ex > maxX then maxX = ox + ex end
                                    if oy - ey < minY then minY = oy - ey end
                                    if oy + ey > maxY then maxY = oy + ey end
                                end
                            end
                        end
                    end
                end)
                if any then
                    cx = math.max(1, math.floor((maxX - minX) / 100.0 + 0.45))
                    cy = math.max(1, math.floor((maxY - minY) / 100.0 + 0.45))
                end
            end
        end)
    end

    if not cx or not cy then
        local cat = Core.IsValidObj(machine) and StationData.GetMachineCategory(machine) or "Other"
        if cat == "Assembler" then cx, cy = 3, 3
        elseif cat == "Container" then cx, cy = 1, 1
        else cx, cy = 1, 1 end
    end

    if clsKey then
        CachedFootprintsByClass[clsKey] = { cellsX = cx, cellsY = cy }
    end
    return cx, cy
end

function StationData.InvalidateCaches()
    CachedPlatforms = { key = nil, time = -999, list = {} }
    CachedMachinesByFrame = {}
    StationDiagLoggedKey = nil
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
