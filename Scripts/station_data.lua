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

function StationData.GetStationFrameTransform(station)
    local act = Core.IsValidObj(station) and StationData.GetObjectActor(station) or nil
    if not Core.IsValidObj(act) and Core.IsValidObj(station) then
        pcall(function() if station.K2_GetActorLocation then act = station end end)
    end
    if not Core.IsValidObj(act) then
        return {
            ox = 0.0, oy = 0.0, oz = 0.0,
            fx = 1.0, fy = 0.0, fz = 0.0,
            rx = 0.0, ry = 1.0, rz = 0.0,
            ux = 0.0, uy = 0.0, uz = 1.0,
            hasActor = false,
            actor = nil,
        }
    end
    local ox, oy, oz = 0.0, 0.0, 0.0
    local fx, fy, fz = 1.0, 0.0, 0.0
    local rx, ry, rz = 0.0, 1.0, 0.0
    local ux, uy, uz = 0.0, 0.0, 1.0
    pcall(function()
        local loc = act:K2_GetActorLocation()
        if loc and type(loc.X) == "number" then ox, oy, oz = loc.X, loc.Y or 0.0, loc.Z or 0.0 end
        local fw = act:GetActorForwardVector()
        if fw and type(fw.X) == "number" then fx, fy, fz = fw.X, fw.Y or 0.0, fw.Z or 0.0 end
        local rt = act:GetActorRightVector()
        if rt and type(rt.X) == "number" then rx, ry, rz = rt.X, rt.Y or 1.0, rt.Z or 0.0 end
        local up = act:GetActorUpVector()
        if up and type(up.X) == "number" then ux, uy, uz = up.X, up.Y or 0.0, up.Z or 1.0 end
    end)
    return {
        ox = ox, oy = oy, oz = oz,
        fx = fx, fy = fy, fz = fz,
        rx = rx, ry = ry, rz = rz,
        ux = ux, uy = uy, uz = uz,
        hasActor = true,
        actor = act,
    }
end

function StationData.WorldToStationLocal(xform, wx, wy, wz, fwdX, fwdY, fwdZ)
    if not xform or not xform.hasActor then
        local yaw = (fwdX and fwdY) and math.deg(math.atan(fwdY, fwdX)) or 0.0
        return wx or 0.0, wy or 0.0, wz or 0.0, yaw
    end
    local dx = (wx or 0.0) - xform.ox
    local dy = (wy or 0.0) - xform.oy
    local dz = (wz or 0.0) - xform.oz
    local lx = dx * xform.fx + dy * xform.fy + dz * xform.fz
    local ly = dx * xform.rx + dy * xform.ry + dz * xform.rz
    local lz = dx * xform.ux + dy * xform.uy + dz * xform.uz
    local yaw = 0.0
    if fwdX and fwdY then
        local fz = fwdZ or 0.0
        local lfx = fwdX * xform.fx + fwdY * xform.fy + fz * xform.fz
        local lfy = fwdX * xform.rx + fwdY * xform.ry + fz * xform.rz
        yaw = math.deg(math.atan(lfy, lfx))
    end
    return lx, ly, lz, yaw
end

function StationData.StationLocalToWorld(xform, lx, ly, lz)
    if not xform or not xform.hasActor then
        return lx or 0.0, ly or 0.0, lz or 0.0
    end
    local wx = xform.ox + lx * xform.fx + ly * xform.rx + lz * xform.ux
    local wy = xform.oy + lx * xform.fy + ly * xform.ry + lz * xform.uy
    local wz = xform.oz + lx * xform.fz + ly * xform.rz + lz * xform.uz
    return wx, wy, wz
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

local function GetMachineLocalPosAndYaw(machine, xform)
    local actor = StationData.GetObjectActor(machine)
    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc and type(loc.X) == "number" then
            local fx, fy, fz = nil, nil, nil
            local okF, fwd = pcall(function() return actor:GetActorForwardVector() end)
            if okF and fwd and type(fwd.X) == "number" then
                fx, fy, fz = fwd.X, fwd.Y or 0.0, fwd.Z or 0.0
            end
            return StationData.WorldToStationLocal(xform, loc.X, loc.Y or 0.0, loc.Z or 0.0, fx, fy, fz)
        end
    end

    local okL, loc = pcall(function() return machine.Location end)
    if okL and loc then
        local x, y, z = Core.GetFPVector(loc)
        -- If actor isn't spawned, check if machine.Location looks station-local vs world
        if xform and xform.hasActor and (math.abs(x - xform.ox) > 200000.0 or math.abs(y - xform.oy) > 200000.0) then
            return x, y, z, 0.0
        end
        return StationData.WorldToStationLocal(xform, x, y, z, nil, nil, nil)
    end
    return 0.0, 0.0, 0.0, 0.0
end

local function CollectElevatorStopLocalZs(station, allMachines, xform)
    local stopLists = {}
    local seenElev = {}
    local elevCls = GetClassCached("ElevatorObject", "/Script/MainSequence.ElevatorObject")

    local function inspectElev(el)
        if not Core.IsValidObj(el) then return end
        local addr = el:GetAddress()
        if seenElev[addr] then return end
        seenElev[addr] = true
        pcall(function()
            local stack = el.ElevatorStack
            if not stack then return end
            local list = {}
            StationData.ForEachArray(stack, function(_, elem)
                local stopObj = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(stopObj) and stopObj.bIsElevatorStop == true then
                    local _, _, lz = GetMachineLocalPosAndYaw(stopObj, xform)
                    table.insert(list, lz)
                end
            end)
            if #list >= 2 then
                table.insert(stopLists, list)
            end
        end)
    end

    if Core.IsValidObj(station) then
        pcall(function()
            if station.Elevators then
                StationData.ForEachArray(station.Elevators, function(_, elem)
                    inspectElev(Core.UnwrapArrayElem(elem))
                end)
            end
        end)
    end
    if allMachines and Core.IsValidObj(elevCls) then
        for _, m in ipairs(allMachines) do
            if Core.IsValidObj(m) and m:IsA(elevCls) then
                inspectElev(m)
            end
        end
    end
    return stopLists
end

function StationData.BuildStationFloorMap(station, walkFrame, playerX, playerY, playerZ)
    local xform = StationData.GetStationFrameTransform(station)
    local plats = StationData.GetStationPlatforms(station, walkFrame)
    if #plats == 0 and Core.IsValidObj(walkFrame) then
        plats = { walkFrame }
    end

    -- Collect all station machines first so we can orient Up axis via ElevatorStack stops
    local allMachines = StationData.GetAllStationMachines(station, plats, walkFrame)

    -- Check ElevatorStack order (stop 1 -> stop N) to ensure local +Z runs Floor 1 (bottom) -> Floor N (top)
    local elevStopLists = CollectElevatorStopLocalZs(station, allMachines, xform)
    local bestElevStops = nil
    for _, sl in ipairs(elevStopLists) do
        if not bestElevStops or #sl > #bestElevStops then bestElevStops = sl end
    end
    if bestElevStops and #bestElevStops >= 2 and bestElevStops[#bestElevStops] < bestElevStops[1] then
        -- Station actor is upside-down (Roll ~ 180 deg): invert Up and Right axes so Floor 1..N ascends and XY isn't mirrored
        xform.ux, xform.uy, xform.uz = -xform.ux, -xform.uy, -xform.uz
        xform.rx, xform.ry, xform.rz = -xform.rx, -xform.ry, -xform.rz
        for _, sl in ipairs(elevStopLists) do
            for k = 1, #sl do sl[k] = -sl[k] end
        end
    end

    local zTolerance = 190.0
    local floors = {}
    local function ensureFloorForZ(lz)
        if type(lz) ~= "number" then return nil end
        for _, fl in ipairs(floors) do
            if math.abs(lz - fl.z) <= zTolerance then
                return fl
            end
        end
        local nf = {
            index = #floors + 1,
            z = lz,
            platforms = {},
            machines = {},
        }
        table.insert(floors, nf)
        return nf
    end

    -- Seed floors from the union of ALL station elevator column stops (authoritative floor count!)
    local hasElevators = (#elevStopLists > 0)
    if hasElevators then
        for _, sl in ipairs(elevStopLists) do
            for _, sz in ipairs(sl) do
                ensureFloorForZ(sz)
            end
        end
    end

    -- Ingest station platforms in station-local coordinates
    local entries = {}
    local minHalf = nil
    for idx1, p in ipairs(plats) do
        local b = StationData.GetPlatformWorldBounds(p, station, idx1)
        local lcx, lcy, lcz = StationData.WorldToStationLocal(xform, b.cx, b.cy, b.cz, nil, nil, nil)
        local localB = {
            cx = lcx, cy = lcy, cz = lcz,
            ex = b.ex, ey = b.ey, ez = b.ez,
            yaw = 0.0,
            id = b.id,
            hasActor = b.hasActor,
        }
        table.insert(entries, { platform = p, bounds = localB })
        local smaller = math.min(b.ex, b.ey)
        if not minHalf or smaller < minHalf then minHalf = smaller end
        if not hasElevators and (#floors == 0 or b.hasActor) then
            local fl = ensureFloorForZ(lcz)
            if fl then table.insert(fl.platforms, { platform = p, bounds = localB }) end
        end
    end

    -- Compute local positions of all machines (only create Z floors from machines when station has NO elevators)
    local localMachines = {}
    for _, m in ipairs(allMachines) do
        local lx, ly, lz, lyaw = GetMachineLocalPosAndYaw(m, xform)
        local skipZero = (not Core.IsValidObj(StationData.GetObjectActor(m))) and math.abs(lx) < 0.5 and math.abs(ly) < 0.5 and math.abs(lz) < 0.5
        if not skipZero then
            table.insert(localMachines, { machine = m, x = lx, y = ly, z = lz, yaw = lyaw })
            if not hasElevators and #floors == 0 then
                ensureFloorForZ(lz)
            end
        end
    end

    if #floors == 0 then
        table.insert(floors, { index = 1, z = 0.0, platforms = entries, machines = {} })
    end

    -- Sort floors bottom-to-top (1 = bottom, N = top)
    table.sort(floors, function(a, b) return a.z < b.z end)
    for i, fl in ipairs(floors) do
        fl.index = i
    end

    -- Bin machines onto their nearest floor by local Z
    for _, lm in ipairs(localMachines) do
        local bestFl, bestDz = nil, math.huge
        for _, fl in ipairs(floors) do
            local dz = math.abs(lm.z - fl.z)
            if dz < bestDz then
                bestDz = dz
                bestFl = fl
            end
        end
        if bestFl then
            table.insert(bestFl.machines, lm)
        end
    end

    -- Ensure each floor has module outlines covering its deck bounds cleanly
    local fallbackPlat = entries[1] and entries[1].platform or walkFrame or station
    for _, fl in ipairs(floors) do
        if #fl.platforms == 0 and #fl.machines > 0 then
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
            table.insert(fl.platforms, {
                platform = fallbackPlat,
                bounds = { cx = cx, cy = cy, cz = fl.z, ex = ex, ey = ey, ez = 200.0, yaw = 0.0, synthetic = true },
            })
        elseif #fl.platforms == 0 then
            table.insert(fl.platforms, {
                platform = fallbackPlat,
                bounds = { cx = 0.0, cy = 0.0, cz = fl.z, ex = 600.0, ey = 600.0, ez = 200.0, yaw = 0.0, synthetic = true },
            })
        end
    end

    local unitSize = (minHalf and minHalf > 100) and (minHalf * 2.0) or 1200.0
    local gridOriginX, gridOriginY = 0.0, 0.0
    local firstB = floors[1] and floors[1].platforms[1] and floors[1].platforms[1].bounds
    if firstB then
        gridOriginX = firstB.cx - firstB.ex
        gridOriginY = firstB.cy - firstB.ey
    end

    -- Select current floor using station-local player Z
    local playerLx, playerLy, playerLz = 0.0, 0.0, 0.0
    if type(playerX) == "number" and type(playerY) == "number" and type(playerZ) == "number" then
        playerLx, playerLy, playerLz = StationData.WorldToStationLocal(xform, playerX, playerY, playerZ, nil, nil, nil)
    end
    local currentFloorIndex = 1
    if #floors > 0 then
        local bestDist = math.huge
        for _, fl in ipairs(floors) do
            local d = math.abs(playerLz - fl.z)
            if d < bestDist then
                bestDist = d
                currentFloorIndex = fl.index
            end
        end
    end

    -- One-shot runtime diagnostic: dump local floors, elevator stops, and non-empty station/actor properties
    local diagKey = Core.IsValidObj(station) and tostring(station:GetAddress()) or "none"
    if StationDiagLoggedKey ~= diagKey then
        StationDiagLoggedKey = diagKey
        local elevStr = bestElevStops and (function()
            local t = {}
            for i, z in ipairs(bestElevStops) do t[i] = string.format("%.0f", z) end
            return table.concat(t, ",")
        end)() or "none"
        local flParts = {}
        for _, fl in ipairs(floors) do
            local sample = fl.machines[1] and Core.IsValidObj(fl.machines[1].machine) and fl.machines[1].machine:GetClass():GetFName():ToString() or "-"
            table.insert(flParts, string.format("#%d(lz=%.0f,m=%d,%s)", fl.index, fl.z, #fl.machines, sample))
        end
        Core.Log(string.format("[StationData] LocalMap playerL=(%.0f,%.0f,%.0f) curFl=%d elevCols=%d elevStops=[%s] floors(%d): %s",
            playerLx, playerLy, playerLz, currentFloorIndex, #elevStopLists, elevStr, #floors, table.concat(flParts, ", ")))

        local clsCounts = {}
        for _, m in ipairs(allMachines) do
            local cn = Core.IsValidObj(m) and m:GetClass():GetFName():ToString() or "?"
            clsCounts[cn] = (clsCounts[cn] or 0) + 1
        end
        local ccList = {}
        for k, v in pairs(clsCounts) do table.insert(ccList, { k = k, v = v }) end
        table.sort(ccList, function(a, b) return a.v > b.v end)
        local topParts = {}
        for i = 1, math.min(10, #ccList) do
            table.insert(topParts, ccList[i].k .. "=" .. ccList[i].v)
        end
        Core.Log("[StationData] TopClasses: " .. table.concat(topParts, ", "))
    end

    return floors, currentFloorIndex, unitSize, gridOriginX, gridOriginY, xform
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

local BeltMatDiagLogged = false
local CachedBeltTexByCls = {}
local CachedBuildablesByCls = nil
local CachedBuildablesByName = nil
local CachedGameTexList = nil
local MissingIconDiagLogged = {}

local function ResolveTextureValue(val)
    if val == nil then return nil end
    if Core.IsValidObj(val) then return val end
    local res = nil
    pcall(function()
        if val.ResourceObject and Core.IsValidObj(val.ResourceObject) then
            res = val.ResourceObject
            return
        end
        if type(val.Get) == "function" then
            local g = val:Get()
            if Core.IsValidObj(g) then res = g return end
        end
        if type(val.ToString) == "function" then
            local p = val:ToString()
            if type(p) == "string" and p ~= "" and p ~= "None" then
                local loaded = Core.FindOrLoadClass(p)
                if Core.IsValidObj(loaded) then res = loaded return end
            end
        end
    end)
    return res
end

local function NormLookupKey(s)
    if type(s) ~= "string" or s == "" then return nil end
    local k = s:lower()
    k = k:gsub("^bpo_", ""):gsub("^bp_", ""):gsub("^da_", ""):gsub("^b_", "")
    k = k:gsub("object_c$", ""):gsub("_c$", "")
    k = k:gsub("[^a-z0-9]+", "")
    return (k ~= "" and k or nil)
end

local function CollectGameTextures()
    if CachedGameTexList then return CachedGameTexList end
    CachedGameTexList = {}
    pcall(function()
        local allTex = FindAllOf("Texture2D")
        if allTex then
            for _, t in ipairs(allTex) do
                if Core.IsValidObj(t) then
                    local okF, full = pcall(function() return t:GetFullName() end)
                    local okN, fname = pcall(function() return t:GetFName():ToString() end)
                    if okF and type(full) == "string" and full:find("/Game/", 1, true) then
                        local fn = (okN and type(fname) == "string") and fname or ""
                        table.insert(CachedGameTexList, {
                            tex = t,
                            name = fn,
                            full = full,
                            lowName = fn:lower(),
                            lowFull = full:lower(),
                            normName = NormLookupKey(fn) or "",
                        })
                    end
                end
            end
        end
    end)
    return CachedGameTexList
end

local function FindBuildableForMachineClass(machine)
    if not Core.IsValidObj(machine) then return nil end
    if not CachedBuildablesByCls then
        CachedBuildablesByCls = {}
        CachedBuildablesByName = {}
        pcall(function()
            local all = FindAllOf("Buildable")
            local clsPropNames = {
                "ObjectClass", "MachineClass", "ActorClass", "ConstructionClass",
                "BuilderClass", "BlockClass", "StationObjectClass", "SpawnClass",
                "PlaceableClass", "PreviewClass", "DockedClass", "DockClass",
            }
            local discoveredExtra = false
            if all then
                for _, b in ipairs(all) do
                    if Core.IsValidObj(b) then
                        if not discoveredExtra then
                            discoveredExtra = true
                            local bCls = b:GetClass()
                            if Core.IsValidObj(bCls) and bCls.ForEachProperty then
                                pcall(function()
                                    bCls:ForEachProperty(function(prop)
                                        local pn = prop:GetFName():ToString()
                                        local low = pn:lower()
                                        if low:find("class", 1, true) or low:find("object", 1, true)
                                            or low:find("actor", 1, true) or low:find("block", 1, true)
                                            or low:find("machine", 1, true)
                                        then
                                            table.insert(clsPropNames, pn)
                                        end
                                    end)
                                end)
                            end
                        end
                        for _, cProp in ipairs(clsPropNames) do
                            local okC, val = pcall(function() return b[cProp] end)
                            if okC and val ~= nil then
                                if Core.IsValidObj(val) then
                                    CachedBuildablesByCls[val:GetAddress()] = b
                                    local okN, fn = pcall(function() return val:GetFName():ToString() end)
                                    if okN and fn then
                                        CachedBuildablesByCls["fn:" .. fn:lower()] = b
                                        local nk = NormLookupKey(fn)
                                        if nk then CachedBuildablesByName[nk] = b end
                                    end
                                else
                                    pcall(function()
                                        if type(val.Get) == "function" then
                                            local g = val:Get()
                                            if Core.IsValidObj(g) then
                                                CachedBuildablesByCls[g:GetAddress()] = b
                                            end
                                        end
                                        if type(val.ToString) == "function" then
                                            local p = val:ToString()
                                            if type(p) == "string" and p ~= "" and p ~= "None" then
                                                CachedBuildablesByCls["path:" .. p:lower()] = b
                                                local short = p:match("([^./]+)$")
                                                if short then
                                                    local nk = NormLookupKey(short)
                                                    if nk then CachedBuildablesByName[nk] = b end
                                                end
                                            end
                                        end
                                    end)
                                end
                            end
                        end
                        pcall(function()
                            local nkF = NormLookupKey(b:GetFName():ToString())
                            if nkF and not CachedBuildablesByName[nkF] then CachedBuildablesByName[nkF] = b end
                            if b.DisplayName then
                                local nkD = NormLookupKey(b.DisplayName:ToString())
                                if nkD and not CachedBuildablesByName[nkD] then CachedBuildablesByName[nkD] = b end
                            end
                        end)
                    end
                end
            end
        end)
    end
    local res = nil
    local function matchClassObj(cls)
        if not Core.IsValidObj(cls) then return nil end
        local byAddr = CachedBuildablesByCls[cls:GetAddress()]
        if byAddr then return byAddr end
        local okF, fn = pcall(function() return cls:GetFName():ToString() end)
        if okF and fn then
            if CachedBuildablesByCls["fn:" .. fn:lower()] then return CachedBuildablesByCls["fn:" .. fn:lower()] end
            local nk = NormLookupKey(fn)
            if nk and CachedBuildablesByName[nk] then return CachedBuildablesByName[nk] end
        end
        local okFull, full = pcall(function() return cls:GetFullName() end)
        if okFull and type(full) == "string" then
            local cp = full:match("^%S+ (.+)$") or full
            if CachedBuildablesByCls["path:" .. cp:lower()] then return CachedBuildablesByCls["path:" .. cp:lower()] end
        end
        return nil
    end

    pcall(function()
        res = matchClassObj(machine:GetClass())
        if not res then
            local actor = StationData.GetObjectActor(machine)
            if Core.IsValidObj(actor) and actor.GetClass then
                res = matchClassObj(actor:GetClass())
            end
        end
    end)
    return res
end

function StationData.GetConveyorBeltTexture(machine)
    if not Core.IsValidObj(machine) then return nil end
    local clsAddr = nil
    pcall(function() clsAddr = machine:GetClass():GetAddress() end)
    if clsAddr and CachedBeltTexByCls[clsAddr] ~= nil then
        return CachedBeltTexByCls[clsAddr] or nil
    end

    local actor = StationData.GetObjectActor(machine)
    if not Core.IsValidObj(actor) then
        pcall(function()
            local okAll, list = pcall(FindAllOf, "ConveyorBeltObject")
            if okAll and list then
                for _, other in ipairs(list) do
                    if Core.IsValidObj(other) and other:GetClass():GetAddress() == clsAddr then
                        local oa = StationData.GetObjectActor(other)
                        if Core.IsValidObj(oa) then actor = oa break end
                    end
                end
            end
        end)
    end

    local bestTex = nil
    local bestScore = -999
    local diagParts = {}
    local matDiag = {}
    local compCount = 0

    local function considerTex(sourceTag, pName, tex)
        if not Core.IsValidObj(tex) then return end
        local tName = ""
        local tFull = ""
        pcall(function() tName = tex:GetFName():ToString() end)
        pcall(function() tFull = tex:GetFullName() end)
        local low = (pName .. " " .. tName .. " " .. tFull):lower()
        if not BeltMatDiagLogged then
            table.insert(diagParts, string.format("%s:%s=%s", sourceTag, pName, tName))
        end
        local score = 0
        if low:find("normal", 1, true) or low:find("_n.", 1, true) or low:find("_n_", 1, true) or tName:lower():match("_n$")
            or low:find("rough", 1, true) or low:find("metal", 1, true) or low:find("_orm", 1, true)
            or low:find("_m.", 1, true) or low:find("_r.", 1, true) or low:find("opacity", 1, true)
            or low:find("mask", 1, true) or low:find("noise", 1, true)
        then
            score = -200
        else
            if low:find("conveyor", 1, true) then score = score + 30 end
            if low:find("belt", 1, true) then score = score + 30 end
            if low:find("arrow", 1, true) or low:find("chevron", 1, true) or low:find("tread", 1, true) or low:find("track", 1, true) then
                score = score + 50
            end
            if low:find("albedo", 1, true) or low:find("diffuse", 1, true) or low:find("basecolor", 1, true)
                or low:find("color", 1, true) or low:find("_bc", 1, true) or low:find("_d", 1, true)
            then
                score = score + 25
            end
            if score == 0 then score = 5 end
        end
        if score > bestScore then
            bestScore = score
            bestTex = tex
        end
    end

    local visitedMats = {}
    local function inspectMat(mat, depth)
        if not Core.IsValidObj(mat) or depth > 4 then return end
        local ma = mat:GetAddress()
        if visitedMats[ma] then return end
        visitedMats[ma] = true

        if not BeltMatDiagLogged then
            local mName, mCls = "?", "?"
            pcall(function() mName = mat:GetFName():ToString() end)
            pcall(function() mCls = mat:GetClass():GetFName():ToString() end)
            table.insert(matDiag, string.format("%s(%s)", mName, mCls))
        end

        pcall(function()
            local tpvs = mat.TextureParameterValues
            if tpvs then
                StationData.ForEachArray(tpvs, function(_, elem)
                    local st = Core.UnwrapStruct(elem)
                    if st then
                        local pName = "?"
                        pcall(function()
                            if st.ParameterInfo and st.ParameterInfo.Name then
                                pName = st.ParameterInfo.Name:ToString()
                            end
                        end)
                        considerTex("TPV", pName, ResolveTextureValue(st.ParameterValue))
                    end
                end)
            end
            for _, refArrName in ipairs({ "ReferencedTextures" }) do
                local okR, refs = pcall(function() return mat[refArrName] end)
                if okR and refs then
                    StationData.ForEachArray(refs, function(_, elem)
                        considerTex("Ref", "ref", ResolveTextureValue(Core.UnwrapArrayElem(elem)))
                    end)
                end
            end
            local okCed, ced = pcall(function() return mat.CachedExpressionData end)
            if okCed and ced and ced.ReferencedTextures then
                StationData.ForEachArray(ced.ReferencedTextures, function(_, elem)
                    considerTex("CED", "ref", ResolveTextureValue(Core.UnwrapArrayElem(elem)))
                end)
            end
            local okExp, exps = pcall(function() return mat.Expressions end)
            if okExp and exps then
                StationData.ForEachArray(exps, function(_, elem)
                    local e = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(e) then
                        local okT, t = pcall(function() return e.Texture end)
                        if okT and t then considerTex("Expr", "expr", ResolveTextureValue(t)) end
                    end
                end)
            end
            if Core.IsValidObj(mat.Parent) then
                inspectMat(mat.Parent, depth + 1)
            end
        end)
    end

    if Core.IsValidObj(actor) then
        pcall(function()
            local meshCls = Core.FindOrLoadClass("/Script/Engine.MeshComponent")
            if Core.IsValidObj(meshCls) and actor.K2_GetComponentsByClass then
                local rawComps = actor:K2_GetComponentsByClass(meshCls)
                StationData.ForEachArray(rawComps, function(_, elem)
                    local c = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(c) then
                        compCount = compCount + 1
                        if c.GetNumMaterials and c.GetMaterial then
                            local nm = math.min(tonumber(c:GetNumMaterials()) or 0, 8)
                            for mi = 0, nm - 1 do
                                inspectMat(c:GetMaterial(mi), 1)
                            end
                        end
                        if c.StaticMesh and c.StaticMesh.StaticMaterials then
                            StationData.ForEachArray(c.StaticMesh.StaticMaterials, function(_, smElem)
                                local smSt = Core.UnwrapStruct(smElem)
                                if smSt and Core.IsValidObj(smSt.MaterialInterface) then
                                    inspectMat(smSt.MaterialInterface, 1)
                                end
                            end)
                        end
                    end
                end)
            end
        end)
    end

    -- Fallback: scan loaded Texture2D assets for conveyor / belt tread textures
    if bestScore <= 5 then
        local allGameTex = CollectGameTextures()
        for _, ti in ipairs(allGameTex) do
            local low = ti.lowFull
            if (low:find("conveyor", 1, true) or low:find("belt", 1, true))
                and not low:find("/ui", 1, true) and not low:find("icon", 1, true)
                and not low:find("thumbnail", 1, true) and not low:find("splitter", 1, true)
                and not low:find("balancer", 1, true) and not low:find("underground", 1, true)
            then
                considerTex("Scan", ti.name, ti.tex)
            end
        end
    end

    if not BeltMatDiagLogged then
        BeltMatDiagLogged = true
        local aName = Core.IsValidObj(actor) and (pcall(function() return actor:GetFName():ToString() end) and actor:GetFName():ToString() or "?") or "nil"
        Core.Log(string.format("[StationData] BeltMatDiag actor=%s comps=%d mats=[%s] bestScore=%d tex=%s params=[%s]",
            aName, compCount, table.concat(matDiag, ", "), bestScore,
            Core.IsValidObj(bestTex) and bestTex:GetFName():ToString() or "nil",
            table.concat(diagParts, ", ")))
    end

    if bestScore <= 0 then bestTex = nil end
    if clsAddr then
        CachedBeltTexByCls[clsAddr] = bestTex or false
    end
    return bestTex
end

function StationData.GetBuildableIconTexture(machine, buildableOpt)
    local bld = Core.IsValidObj(buildableOpt) and buildableOpt or nil
    if not bld and Core.IsValidObj(machine) then
        pcall(function() bld = machine.Buildable end)
        if not Core.IsValidObj(bld) then
            local actor = StationData.GetObjectActor(machine)
            if Core.IsValidObj(actor) then
                pcall(function() bld = actor.Buildable or actor.BuildableData end)
            end
        end
        if not Core.IsValidObj(bld) then
            bld = FindBuildableForMachineClass(machine)
        end
    end
    if Core.IsValidObj(bld) then
        for _, prop in ipairs({ "Icon", "Texture", "IconTexture", "Image", "Thumbnail" }) do
            local ok, v = pcall(function() return bld[prop] end)
            if ok and v ~= nil then
                local tex = ResolveTextureValue(v)
                if Core.IsValidObj(tex) then return tex end
            end
        end
        local okD, det = pcall(function() return bld.ItemDetails end)
        if okD and det then
            for _, prop in ipairs({ "Icon", "Texture", "Image" }) do
                local ok, v = pcall(function() return det[prop] end)
                if ok and v ~= nil then
                    local tex = ResolveTextureValue(v)
                    if Core.IsValidObj(tex) then return tex end
                end
            end
        end
    end
    if Core.IsValidObj(machine) then
        for _, prop in ipairs({ "Icon", "Texture", "IconTexture", "Image", "Thumbnail" }) do
            local ok, v = pcall(function() return machine[prop] end)
            if ok and v ~= nil then
                local tex = ResolveTextureValue(v)
                if Core.IsValidObj(tex) then return tex end
            end
        end
        -- Fallback: check machine/actor properties referencing another data asset (Dock/Block/Data)
        local candidates = { machine }
        local actor = StationData.GetObjectActor(machine)
        if Core.IsValidObj(actor) then table.insert(candidates, actor) end
        for _, owner in ipairs(candidates) do
            for _, subProp in ipairs({ "Dock", "Block", "DockData", "BlockData", "Definition", "Data", "Config" }) do
                local okS, sub = pcall(function() return owner[subProp] end)
                if okS and Core.IsValidObj(sub) then
                    for _, ip in ipairs({ "Icon", "Texture", "IconTexture", "Image" }) do
                        local okI, v = pcall(function() return sub[ip] end)
                        if okI and v ~= nil then
                            local tex = ResolveTextureValue(v)
                            if Core.IsValidObj(tex) then return tex end
                        end
                    end
                end
            end
        end

        -- Fallback 2: search loaded Texture2D UI/Icon assets matching normalized class/name tokens
        local clsKey = ""
        pcall(function() clsKey = machine:GetClass():GetFName():ToString() end)
        local mNorm = NormLookupKey(clsKey) or ""
        local dispNorm = NormLookupKey(StationData.GetMachineDisplayName(machine)) or ""
        local allTex = CollectGameTextures()
        local bestTex, bestScore = nil, 0
        for _, ti in ipairs(allTex) do
            local lf = ti.lowFull
            if not lf:find("_n.", 1, true) and not lf:find("_orm", 1, true) and not lf:find("normal", 1, true) then
                local sc = 0
                if mNorm ~= "" and ti.normName:find(mNorm, 1, true) then sc = sc + 80 end
                if dispNorm ~= "" and ti.normName:find(dispNorm, 1, true) then sc = sc + 70 end
                -- Token matching (e.g. shipyard + dock, station + dock)
                if (mNorm:find("shipyard", 1, true) or dispNorm:find("shipyard", 1, true)) and lf:find("shipyard", 1, true) then
                    sc = sc + 35
                    if lf:find("dock", 1, true) then sc = sc + 35 end
                elseif (mNorm:find("stationblock", 1, true) or dispNorm:find("stationblock", 1, true) or mNorm:find("stationdock", 1, true))
                    and lf:find("station", 1, true) and lf:find("dock", 1, true)
                then
                    sc = sc + 65
                end
                if sc > 0 then
                    if lf:find("/ui", 1, true) or lf:find("icon", 1, true) or ti.lowName:match("^t_") then sc = sc + 20 end
                    if sc > bestScore then bestScore = sc; bestTex = ti.tex end
                end
            end
        end
        if Core.IsValidObj(bestTex) and bestScore >= 60 then
            return bestTex
        end

        if clsKey ~= "" and not MissingIconDiagLogged[clsKey] then
            MissingIconDiagLogged[clsKey] = true
            local bProps = {}
            pcall(function()
                local allB = FindAllOf("Buildable")
                if allB and allB[1] and allB[1]:GetClass() and allB[1]:GetClass().ForEachProperty then
                    allB[1]:GetClass():ForEachProperty(function(p)
                        table.insert(bProps, p:GetFName():ToString())
                    end)
                end
            end)
            Core.Log(string.format("[StationData] MissingIconDiag cls=%s mNorm=%s bestTex=%s(%d) buildableProps=[%s]",
                clsKey, mNorm, Core.IsValidObj(bestTex) and bestTex:GetFName():ToString() or "nil", bestScore, table.concat(bProps, ",")))
        end
    end
    return nil
end

function StationData.GetMachineTypeAndTier(machine, buildableOpt)
    local bld = Core.IsValidObj(buildableOpt) and buildableOpt or nil
    if not bld and Core.IsValidObj(machine) then
        pcall(function() bld = machine.Buildable end)
    end

    local dispName = ""
    if Core.IsValidObj(bld) then
        pcall(function()
            if bld.DisplayName then dispName = bld.DisplayName:ToString() end
        end)
    end
    if dispName == "" and Core.IsValidObj(machine) then
        dispName = StationData.GetMachineDisplayName(machine)
    end

    local clsName = ""
    if Core.IsValidObj(machine) then
        pcall(function() clsName = machine:GetClass():GetFName():ToString() end)
    elseif Core.IsValidObj(bld) then
        pcall(function() clsName = bld:GetFName():ToString() end)
    end

    -- Detect tier from Buildable.Tier, DisplayName (Mk. 2 / Mk 3 / II / III), or class suffix (_02 / _2)
    local tier = nil
    if Core.IsValidObj(bld) then
        pcall(function()
            local bt = tonumber(bld.Tier)
            if bt and bt >= 1 then tier = math.floor(bt) end
        end)
    end
    if not tier then
        local dn = dispName
        local mk = dn:match("[Mm][Kk]%.?%s*(%d+)") or dn:match("[Tt]ier%s*(%d+)") or dn:match("%s+(%d+)$")
        if mk then
            tier = tonumber(mk)
        elseif dn:match("%s+IV$") then tier = 4
        elseif dn:match("%s+III$") then tier = 3
        elseif dn:match("%s+II$") then tier = 2
        elseif dn:match("%s+I$") then tier = 1
        end
    end
    if not tier then
        local cnMk = clsName:match("_[Mm][Kk](%d+)") or clsName:match("_0?(%d+)[A-Za-z]?_C$")
        if cnMk then
            tier = tonumber(cnMk)
        end
    end
    tier = Core.Clamp(tier or 1, 1, 6)

    -- Normalize type key by stripping tier suffix and prefixes
    local base = (dispName ~= "" and dispName or clsName):lower()
    base = base:gsub("^bpo_", ""):gsub("^bp_", ""):gsub("object_c$", ""):gsub("_c$", "")
    base = base:gsub("%s*[Tt]ier%s*%d+", ""):gsub("%s*[Mm][Kk]%.?%s*%d+", "")
    base = base:gsub("%s+iv$", ""):gsub("%s+iii$", ""):gsub("%s+ii$", ""):gsub("%s+i$", "")
    base = base:gsub("_[%d]+[a-z]?$", ""):gsub("%s+%d+$", "")
    base = base:gsub("[^a-z0-9]+", " "):match("^%s*(.-)%s*$") or "machine"
    if base == "" then base = "machine" end

    return base, tier, (dispName ~= "" and dispName or "Machine")
end

function StationData.GetContainerTopItems(container, maxCount)
    local items = {}
    local inv = StationData.GetContainerInventory(container)
    if not Core.IsValidObj(inv) then return items end

    local byKey = {}
    local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
    if okSlots and slots then
        StationData.ForEachArray(slots, function(_, elem)
            local st = Core.UnwrapStruct(elem)
            if st and Core.IsValidObj(st.Item) then
                local amt = tonumber(st.Amount) or 0
                if amt > 0 then
                    local k = StationData.GetObjectKey(st.Item)
                    if not byKey[k] then
                        byKey[k] = { Item = st.Item, Amount = 0 }
                    end
                    byKey[k].Amount = byKey[k].Amount + amt
                end
            end
        end)
    end
    for _, e in pairs(byKey) do
        table.insert(items, e)
    end
    table.sort(items, function(a, b) return a.Amount > b.Amount end)
    if maxCount and #items > maxCount then
        while #items > maxCount do table.remove(items) end
    end
    return items
end

function StationData.GetProducerOutputsAndRates(machine)
    local outputs = {}
    if not Core.IsValidObj(machine) then return outputs end

    local rec = nil
    pcall(function() rec = machine.Recipe end)
    if not Core.IsValidObj(rec) then return outputs end

    local bonusMult = 1.0
    pcall(function()
        local bm = Core.GetFPFloat(machine.BonusMultiplier)
        if bm > 0.0001 then bonusMult = bm end
    end)

    local craftSec = 1.0
    local okSec, sec = pcall(function() return rec:GetCraftingSeconds() end)
    if okSec and type(sec) == "number" and sec > 0.0001 then
        craftSec = sec
    end

    local okOut, outStack = pcall(function() return rec.Output end)
    if okOut and outStack and Core.IsValidObj(outStack.Item) then
        local amt = tonumber(outStack.Amount) or 1
        local rate = (amt * 60.0 / craftSec) * bonusMult
        table.insert(outputs, { Item = outStack.Item, Rate = rate })
        return outputs
    end

    local okOuts, outs = pcall(function() return rec:GetOutputs() end)
    if okOuts and outs then
        StationData.ForEachArray(outs, function(_, elem)
            local st = Core.UnwrapStruct(elem)
            if st and Core.IsValidObj(st.Item) then
                local amt = tonumber(st.Amount) or 1
                local rate = (amt * 60.0 / craftSec) * bonusMult
                table.insert(outputs, { Item = st.Item, Rate = rate })
            end
        end)
    end
    return outputs
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
    CachedFootprintsByClass = {}
    CachedBeltTexByCls = {}
    CachedBuildablesByCls = nil
    CachedBuildablesByName = nil
    CachedGameTexList = nil
    MissingIconDiagLogged = {}
    BeltMatDiagLogged = false
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
