-- Eqol Feature: Elevator Port Item Icons (3D World-Space WidgetComponent)
-- Displays the item icon from each populated UElevatorObject.ItemColumns slot
-- directly on the blank gray panel above the matching conveyor port across every
-- stacked elevator module in that shaft (above and below the feeder floor).

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "ElevatorLabels",
}

local PATHS = {
    WBPItemClass    = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    ActorClass      = "/Script/Engine.Actor",
    WidgetCompClass = "/Script/UMG.WidgetComponent",
    KismetMathLib   = "/Script/Engine.Default__KismetMathLibrary",
    WorldUtilsCDO   = "/Script/MainSequence.Default__WorldUtils",
}

local COLORS = {
    PanelBg = { R = 0.015, G = 0.015, B = 0.02, A = 1.0 },
}

local GRID_UNIT_CM         = 50.0   -- Elevator Inputs use 50 cm grid units (+-13->+-650cm, +-6->+-300cm)
local PORT_WALL_OFFSET_CM  = 297.0  -- cm along port facing axis (3cm proud of +-300cm port seam)
local PANEL_Z_ABOVE_STOP   = 156.0  -- cm along actor Up from stopPos (centered on blank gray plate)
local MAX_VIEW_DIST_SQ     = 3000.0 * 3000.0
local ICON_PIXEL_SIZE      = 64.0
local ICON_WORLD_SCALE     = 0.72   -- ~46 cm black square panel inside blank gray plate
local ICON_INNER_SCALE     = 0.74   -- ~34 cm item icon padded inside the black square panel
local ELEVATOR_SCAN_PERIOD = 1.5
local PORT_DATA_PERIOD     = 0.25

local CachedElevActors = {} -- actorAddr -> AElevator
local CachedObjToActor = {} -- elevObjAddr -> AElevator
local CachedWorldPorts = {} -- list of { ShaftHex, ColIdx, StopIdx, X, Y, Z, Nx, Ny, Nz, Ux, Uy, Uz, Item, ItemAddr }
local IconPool         = {} -- idx -> { Actor, Comp, ItemWidget, LastItemAddr }
local LastElevatorScan = -10.0
local LastPortRefresh  = -10.0
local LoggedShafts     = {}
local PollActive       = false

local function LogOnce(key, fmt, ...)
    if LoggedShafts[key] then return end
    LoggedShafts[key] = true
    local okMsg, msg = pcall(string.format, fmt, ...)
    if okMsg then
        Core.Log("[ElevatorLabels] " .. msg)
    end
end

local function SafeObjName(obj)
    if not Core.IsValidObj(obj) then return "invalid" end
    local name = nil
    pcall(function()
        if obj.GetFName then
            name = obj:GetFName():ToString()
        elseif obj.GetFullName then
            name = obj:GetFullName()
        end
    end)
    return name or string.format("0x%X", tonumber(obj:GetAddress()) or 0)
end

local function ExtractArray(tarr)
    local out = {}
    local count = 0
    if not tarr then return out, 0 end
    StationData.ForEachArray(tarr, function(idx, elem)
        if idx > count then count = idx end
        out[idx] = Core.UnwrapArrayElem(elem)
    end)
    return out, count
end

local function DestroyIconPool()
    for i, entry in ipairs(IconPool) do
        if entry and Core.IsValidObj(entry.Actor) then
            pcall(function() entry.Actor:K2_DestroyActor() end)
        end
        IconPool[i] = nil
    end
end

local function GetOrCreateIconActor(pc, idx)
    local entry = IconPool[idx]
    if entry and Core.IsValidObj(entry.Actor) and Core.IsValidObj(entry.Comp) and Core.IsValidObj(entry.ItemWidget) then
        return entry
    end

    local compCls = Core.FindOrLoadClass(PATHS.WidgetCompClass)
    if not Core.IsValidObj(compCls) then
        LogOnce("err:compCls", "Step[IconPool#%d] FAILED FindOrLoadClass(%s)", idx, PATHS.WidgetCompClass)
        return nil
    end

    local actor = Core.SpawnActor(pc, PATHS.ActorClass, { X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    if not Core.IsValidObj(actor) then
        LogOnce("err:spawn" .. idx, "Step[IconPool#%d] FAILED SpawnActor(%s)", idx, PATHS.ActorClass)
        return nil
    end

    local xform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local okC, comp = pcall(function()
        return actor:AddComponentByClass(compCls, false, xform, false)
    end)
    if not okC or not Core.IsValidObj(comp) then
        LogOnce("err:addComp" .. idx, "Step[IconPool#%d] FAILED AddComponentByClass: %s", idx, tostring(comp))
        pcall(function() actor:K2_DestroyActor() end)
        return nil
    end

    local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, pc, pc)
    if not Core.IsValidObj(itemW) then
        LogOnce("err:itemW" .. idx, "Step[IconPool#%d] FAILED CreateUserWidget(%s)", idx, PATHS.WBPItemClass)
        pcall(function() actor:K2_DestroyActor() end)
        return nil
    end

    local okSetup, errSetup = pcall(function()
        itemW.TooltipEnabled = false
        itemW:SetIconSize(ICON_PIXEL_SIZE)
        itemW:SetVisibility(0)
        comp:SetWidgetSpace(0) -- World space
        comp:SetDrawSize({ X = ICON_PIXEL_SIZE, Y = ICON_PIXEL_SIZE })
        comp:SetDrawAtDesiredSize(true)
        comp:SetPivot({ X = 0.5, Y = 0.5 })
        comp:SetTwoSided(true)
        comp:SetBackgroundColor(COLORS.PanelBg)
        comp:SetWidget(itemW)
        comp:SetWorldScale3D({ X = ICON_WORLD_SCALE, Y = ICON_WORLD_SCALE, Z = ICON_WORLD_SCALE })
        comp:SetVisibility(false, false)
    end)
    if not okSetup then
        LogOnce("err:setup" .. idx, "Step[IconPool#%d] setup error: %s", idx, tostring(errSetup))
    end
    local okPad, errPad = pcall(function()
        itemW:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        itemW:SetRenderScale({ X = ICON_INNER_SCALE, Y = ICON_INNER_SCALE })
    end)
    if not okPad then
        LogOnce("err:innerScale" .. idx, "Step[IconPool#%d] inner scale warning: %s", idx, tostring(errPad))
    end
    pcall(function() comp:SetCollisionEnabled(0) end)

    LogOnce("pool:" .. idx,
        "Step[IconPool#%d] Created actor=0x%X comp=0x%X widget=0x%X scale=%.2f px=%.0f",
        idx, tonumber(actor:GetAddress()) or 0, tonumber(comp:GetAddress()) or 0,
        tonumber(itemW:GetAddress()) or 0, ICON_WORLD_SCALE, ICON_PIXEL_SIZE)

    entry = {
        Actor = actor,
        Comp = comp,
        ItemWidget = itemW,
        LastItemAddr = nil,
    }
    IconPool[idx] = entry
    return entry
end

local function GetElevatorObject(elevActor)
    if not Core.IsValidObj(elevActor) then return nil end
    local obj = nil
    pcall(function()
        if Core.IsValidObj(elevActor.ElevatorObject) then
            obj = elevActor.ElevatorObject
        end
    end)
    if Core.IsValidObj(obj) then return obj end

    pcall(function()
        if elevActor.GetSimulationObject then
            local sim = elevActor:GetSimulationObject()
            if Core.IsValidObj(sim) then
                obj = sim
            end
        end
    end)
    return obj
end

local function RefreshElevatorActorCache(force)
    local now = os.clock()
    if not force and (now - LastElevatorScan) < ELEVATOR_SCAN_PERIOD then
        return
    end
    LastElevatorScan = now

    local nextActors = {}
    local nextObjMap = {}
    local actorCount, mappedCount = 0, 0
    local ok, actors = pcall(FindAllOf, "Elevator")
    if not ok then
        LogOnce("err:findElev", "Step[Scan] FAILED FindAllOf(Elevator): %s", tostring(actors))
    elseif actors then
        for _, actor in ipairs(actors) do
            if Core.IsValidObj(actor) then
                actorCount = actorCount + 1
                nextActors[actor:GetAddress()] = actor
                local elevObj = GetElevatorObject(actor)
                if Core.IsValidObj(elevObj) then
                    mappedCount = mappedCount + 1
                    nextObjMap[elevObj:GetAddress()] = actor
                else
                    LogOnce("err:elevObj:" .. tostring(actor:GetAddress()),
                        "Step[Scan] AElevator 0x%X (%s) has no ElevatorObject",
                        tonumber(actor:GetAddress()) or 0, SafeObjName(actor))
                end
            end
        end
    end
    CachedElevActors = nextActors
    CachedObjToActor = nextObjMap
    LogOnce(string.format("scan:%d:%d", actorCount, mappedCount),
        "Step[Scan] Found AElevator actors=%d mappedToSimObj=%d", actorCount, mappedCount)
end

local function GetBottomElevator(elevObj)
    if not Core.IsValidObj(elevObj) then return nil end
    local bottom = nil
    pcall(function()
        if elevObj.GetBottomElevator then
            local b = elevObj:GetBottomElevator()
            if Core.IsValidObj(b) then
                bottom = b
            end
        end
    end)
    if Core.IsValidObj(bottom) then return bottom end

    pcall(function()
        local stack = ExtractArray(elevObj.ElevatorStack)
        if Core.IsValidObj(stack[1]) then
            bottom = stack[1]
        end
    end)
    if Core.IsValidObj(bottom) then return bottom end
    return elevObj
end

local function GetActorFromSimObj(simObj)
    if not Core.IsValidObj(simObj) then return nil, "invalidSim" end

    local mapped = CachedObjToActor[simObj:GetAddress()]
    if Core.IsValidObj(mapped) then
        return mapped, "objMap"
    end

    if StationData.GetObjectActor then
        local okSt, stActor = pcall(StationData.GetObjectActor, simObj)
        if okSt and Core.IsValidObj(stActor) then
            return stActor, "stationData"
        end
    end

    local actor = nil
    pcall(function()
        local actors = ExtractArray(simObj.Actors)
        if Core.IsValidObj(actors[1]) then
            actor = actors[1]
        end
    end)
    if Core.IsValidObj(actor) then
        return actor, "simActors"
    end
    return nil, "none"
end

local function SafeCompLocalPos(comp, pos, fw, rt, up)
    if not Core.IsValidObj(comp) or not comp.K2_GetComponentLocation then return nil end
    local out = nil
    pcall(function()
        local loc = comp:K2_GetComponentLocation()
        if loc and type(loc.X) == "number" then
            local dx = loc.X - pos.X
            local dy = loc.Y - pos.Y
            local dz = loc.Z - pos.Z
            out = {
                lx = dx * fw.X + dy * fw.Y + dz * fw.Z,
                ly = dx * rt.X + dy * rt.Y + dz * rt.Z,
                lz = dx * up.X + dy * up.Y + dz * up.Z,
                wx = loc.X, wy = loc.Y, wz = loc.Z,
            }
        end
    end)
    return out
end

local function FormatLocalPos(lp)
    if not lp then return "nil" end
    return string.format("(%.1f,%.1f,%.1f)", lp.lx, lp.ly, lp.lz)
end

local function SafeCompWorldAndLocal(comp, pos, fw, rt, up)
    local lp = SafeCompLocalPos(comp, pos, fw, rt, up)
    if not lp then return nil end
    local rotStr = ""
    pcall(function()
        local f = comp.GetForwardVector and comp:GetForwardVector() or nil
        if f and type(f.X) == "number" then
            local fx = f.X * fw.X + f.Y * fw.Y + f.Z * fw.Z
            local fy = f.X * rt.X + f.Y * rt.Y + f.Z * rt.Z
            local fz = f.X * up.X + f.Y * up.Y + f.Z * up.Z
            rotStr = string.format(" fw=(%.2f,%.2f,%.2f)", fx, fy, fz)
        end
    end)
    return FormatLocalPos(lp) .. rotStr
end

local function LogShaftFullGeometry(bAddr, bHex, bottomElev, stopFrames, stackCount)
    if LoggedShafts[bAddr .. ":fullGeo"] then return end
    LoggedShafts[bAddr .. ":fullGeo"] = true

    -- 1. All Inputs & Outputs of bottomElev
    local function fmtVecArr(arrRaw)
        local arr, n = ExtractArray(arrRaw)
        local parts = {}
        for i = 1, n do
            local v = arr[i]
            if v then
                local vx, vy, vz, okXY = 0.0, 0.0, 0.0, false
                pcall(function()
                    vx = tonumber(v.X) or 0.0
                    vy = tonumber(v.Y) or 0.0
                    okXY = true
                    vz = tonumber(v.Z) or 0.0
                end)
                parts[#parts + 1] = okXY and string.format("#%d=(%.1f,%.1f,%.1f)", i, vx, vy, vz) or ("#" .. i .. "=err")
            end
        end
        return n, table.concat(parts, " ")
    end

    local okIn, inRaw = pcall(function() return bottomElev.Inputs end)
    local inN, inStr = 0, "nil"
    if okIn and inRaw then inN, inStr = fmtVecArr(inRaw) end

    local okOut, outRaw = pcall(function() return bottomElev.Outputs end)
    local outN, outStr = 0, "nil"
    if okOut and outRaw then outN, outStr = fmtVecArr(outRaw) end

    local locPropStr = "nil"
    pcall(function()
        local l = bottomElev.Location
        if l then
            local x, y, z = Core.GetFPVector(l)
            locPropStr = string.format("(%.1f,%.1f,%.1f)", x, y, z)
        end
    end)
    Core.Log(string.format("[ElevatorLabels] Geo[%s] objLoc=%s Inputs(%d)=[%s] Outputs(%d)=[%s]",
        bHex, locPropStr, inN, inStr, outN, outStr))

    -- 2. All doors/calls/widgets + StaticMeshComponents on first loaded stop actor
    local refFrame = nil
    for sIdx = 1, stackCount do
        if stopFrames[sIdx] and stopFrames[sIdx].HasActor then
            refFrame = stopFrames[sIdx]
            break
        end
    end
    if refFrame and Core.IsValidObj(refFrame.Actor) then
        local a = refFrame.Actor
        local p, fw, rt, up = refFrame.Pos, refFrame.Fw, refFrame.Rt, refFrame.Up
        local doorNames = { "BPC_Door", "BPC_Door1", "BPC_Door2", "BPC_Door3", "CallInteraction", "CallInteraction1", "CallInteraction2", "CallInteraction3", "Widget", "Widget1", "Widget2", "Widget3" }
        local compParts = {}
        for _, cname in ipairs(doorNames) do
            local okP, cobj = pcall(function() return a[cname] end)
            if okP and Core.IsValidObj(cobj) then
                local desc = SafeCompWorldAndLocal(cobj, p, fw, rt, up)
                if desc then
                    compParts[#compParts + 1] = cname .. "=" .. desc
                end
            end
        end
        Core.Log(string.format("[ElevatorLabels] Geo[%s] NamedComps: %s", bHex, table.concat(compParts, " | ")))

        local smParts = {}
        pcall(function()
            local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
            if not Core.IsValidObj(smCls) or not a.K2_GetComponentsByClass then return end
            local list, n = ExtractArray(a:K2_GetComponentsByClass(smCls))
            for i = 1, n do
                local c = list[i]
                if Core.IsValidObj(c) then
                    local smName = "none"
                    local extStr = ""
                    pcall(function()
                        local sm = c.StaticMesh
                        if Core.IsValidObj(sm) then
                            smName = SafeObjName(sm)
                            local eb = sm.ExtendedBounds
                            if eb and eb.BoxExtent then
                                extStr = string.format(" ext=(%.0f,%.0f,%.0f)",
                                    tonumber(eb.BoxExtent.X) or 0, tonumber(eb.BoxExtent.Y) or 0, tonumber(eb.BoxExtent.Z) or 0)
                            end
                        end
                    end)
                    local lp = SafeCompLocalPos(c, p, fw, rt, up)
                    smParts[#smParts + 1] = string.format("%s(%s%s)@%s", SafeObjName(c), smName, extStr, FormatLocalPos(lp))
                end
            end
        end)
        Core.Log(string.format("[ElevatorLabels] Geo[%s] StaticMeshes(%d): %s", bHex, #smParts, table.concat(smParts, "; ")))
    end

    -- 3. Nearby ConveyorBelts relative to shaft stops (proves exact port X/Y/Z in actor frame)
    if refFrame then
        local belts = nil
        local okB, bList = pcall(FindAllOf, "ConveyorBeltObject")
        if okB and bList and #bList > 0 then
            belts = bList
        else
            local okM, mList = pcall(FindAllOf, "MachineObject")
            if okM and mList then
                belts = {}
                for _, m in ipairs(mList) do
                    if StationData.GetMachineCategory(m) == "Conveyor" then
                        belts[#belts + 1] = m
                    end
                end
            end
        end
        if belts then
            local nearBelts = {}
            for _, b in ipairs(belts) do
                if Core.IsValidObj(b) then
                    local bAct = StationData.GetObjectActor and StationData.GetObjectActor(b) or nil
                    local bx, by, bz = nil, nil, nil
                    local bFw = nil
                    if Core.IsValidObj(bAct) then
                        pcall(function()
                            local l = bAct:K2_GetActorLocation()
                            if l and type(l.X) == "number" then bx, by, bz = l.X, l.Y, l.Z end
                            local f = bAct:GetActorForwardVector()
                            if f and type(f.X) == "number" then bFw = { X = f.X, Y = f.Y, Z = f.Z } end
                        end)
                    end
                    if not bx then
                        local okPos, mx, my, mz = pcall(StationData.GetMachineWorldPosAndYaw, b, nil)
                        if okPos and type(mx) == "number" then bx, by, bz = mx, my, mz end
                    end
                    if bx then
                        local bestS, bestD2, bestF = nil, nil, nil
                        for sIdx = 1, stackCount do
                            local f = stopFrames[sIdx]
                            if f then
                                local dx, dy, dz = bx - f.Pos.X, by - f.Pos.Y, bz - f.Pos.Z
                                local d2 = dx * dx + dy * dy + dz * dz
                                if d2 <= (1500.0 * 1500.0) and (not bestD2 or d2 < bestD2) then
                                    bestD2, bestS, bestF = d2, sIdx, f
                                end
                            end
                        end
                        if bestF then
                            local dx, dy, dz = bx - bestF.Pos.X, by - bestF.Pos.Y, bz - bestF.Pos.Z
                            local lx = dx * bestF.Fw.X + dy * bestF.Fw.Y + dz * bestF.Fw.Z
                            local ly = dx * bestF.Rt.X + dy * bestF.Rt.Y + dz * bestF.Rt.Z
                            local lz = dx * bestF.Up.X + dy * bestF.Up.Y + dz * bestF.Up.Z
                            local fStr = ""
                            if bFw then
                                local flx = bFw.X * bestF.Fw.X + bFw.Y * bestF.Fw.Y + bFw.Z * bestF.Fw.Z
                                local fly = bFw.X * bestF.Rt.X + bFw.Y * bestF.Rt.Y + bFw.Z * bestF.Rt.Z
                                fStr = string.format(" bFw=(%.2f,%.2f)", flx, fly)
                            end
                            local curItem = StationData.GetPrimaryItemForMachine and StationData.GetPrimaryItemForMachine(b) or nil
                            nearBelts[#nearBelts + 1] = {
                                d2 = bestD2,
                                line = string.format("stop#%d d=%.0f local=(%.1f,%.1f,%.1f)%s item=%s",
                                    bestS, math.sqrt(bestD2), lx, ly, lz, fStr, SafeObjName(curItem))
                            }
                        end
                    end
                end
            end
            table.sort(nearBelts, function(a, b) return a.d2 < b.d2 end)
            local limit = math.min(#nearBelts, 12)
            local out = {}
            for i = 1, limit do out[i] = nearBelts[i].line end
            Core.Log(string.format("[ElevatorLabels] Geo[%s] NearBelts(%d/%d): %s", bHex, #nearBelts, #belts, table.concat(out, " | ")))
        end
    end
end

local function GetActorStaticMeshDiag(actor)
    if not Core.IsValidObj(actor) then return nil end
    local parts = {}
    pcall(function()
        local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
        if not Core.IsValidObj(smCls) or not actor.K2_GetComponentsByClass then return end
        local comps = actor:K2_GetComponentsByClass(smCls)
        local list, n = ExtractArray(comps)
        for i = 1, math.min(n, 4) do
            local c = list[i]
            if Core.IsValidObj(c) then
                local smName = "none"
                local extStr = ""
                pcall(function()
                    local sm = c.StaticMesh
                    if Core.IsValidObj(sm) then
                        smName = SafeObjName(sm)
                        local eb = sm.ExtendedBounds
                        if eb and eb.BoxExtent and eb.Origin then
                            extStr = string.format(" orig=(%.1f,%.1f,%.1f) ext=(%.1f,%.1f,%.1f)",
                                tonumber(eb.Origin.X) or 0, tonumber(eb.Origin.Y) or 0, tonumber(eb.Origin.Z) or 0,
                                tonumber(eb.BoxExtent.X) or 0, tonumber(eb.BoxExtent.Y) or 0, tonumber(eb.BoxExtent.Z) or 0)
                        end
                    end
                end)
                parts[#parts + 1] = smName .. extStr
            end
        end
    end)
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

local function GetStopFrameInfo(stopObj)
    local actor, actorSrc = GetActorFromSimObj(stopObj)
    local pos = nil
    local posSrc = "none"
    local rot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    local fw = { X = 1.0, Y = 0.0, Z = 0.0 }
    local rt = { X = 0.0, Y = 1.0, Z = 0.0 }
    local up = { X = 0.0, Y = 0.0, Z = 1.0 }
    local diag = nil
    local hasActor = false

    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc and type(loc.X) == "number" then
            pos = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }
            posSrc = "actorLoc"
        end
        pcall(function()
            local r = actor:GetActorRotation()
            if r and type(r.Yaw) == "number" then
                rot = { Pitch = tonumber(r.Pitch) or 0.0, Yaw = tonumber(r.Yaw) or 0.0, Roll = tonumber(r.Roll) or 0.0 }
            end
        end)
        pcall(function()
            local f = actor:GetActorForwardVector()
            local r = actor:GetActorRightVector()
            local u = actor:GetActorUpVector()
            if f and type(f.X) == "number" then fw = { X = f.X, Y = f.Y, Z = f.Z } end
            if r and type(r.X) == "number" then rt = { X = r.X, Y = r.Y, Z = r.Z } end
            if u and type(u.X) == "number" then up = { X = u.X, Y = u.Y, Z = u.Z } end
        end)
        if pos then
            hasActor = true
            diag = {
                doorLocal = SafeCompLocalPos(actor.BPC_Door, pos, fw, rt, up),
                wigLocal  = SafeCompLocalPos(actor.Widget, pos, fw, rt, up),
                callLocal = SafeCompLocalPos(actor.CallInteraction, pos, fw, rt, up),
                meshDiag  = GetActorStaticMeshDiag(actor),
            }
        end
    end

    if not pos then
        local okM, mx, my, mz, mYaw = pcall(StationData.GetMachineWorldPosAndYaw, stopObj, nil)
        if okM and type(mx) == "number" then
            pos = { X = mx, Y = my or 0.0, Z = mz or 0.0 }
            rot.Yaw = mYaw or 0.0
            local rad = math.rad(rot.Yaw)
            fw = { X = math.cos(rad), Y = math.sin(rad), Z = 0.0 }
            rt = { X = -math.sin(rad), Y = math.cos(rad), Z = 0.0 }
            posSrc = "machinePos"
        end
    end
    if not pos then
        local worldUtils = Core.GetCDO(PATHS.WorldUtilsCDO)
        if Core.IsValidObj(worldUtils) and worldUtils.GetObjectWorldLocation then
            local okLoc, loc = pcall(function() return worldUtils:GetObjectWorldLocation(stopObj) end)
            if okLoc and loc then
                pos = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }
                posSrc = "worldUtils"
            end
        end
    end
    if not pos then
        LogOnce("err:stopPos:" .. tostring(stopObj:GetAddress()),
            "Step[StopFrame] FAILED resolving world pos for stopObj=0x%X actorSrc=%s",
            tonumber(stopObj:GetAddress()) or 0, actorSrc)
        return nil
    end

    return {
        StopAddr = tonumber(stopObj:GetAddress()) or 0,
        Pos = pos,
        Rot = rot,
        Yaw = rot.Yaw,
        Fw = fw,
        Rt = rt,
        Up = up,
        Actor = actor,
        ActorSrc = actorSrc,
        PosSrc = posSrc,
        HasActor = hasActor,
        InheritedBasis = false,
        Diag = diag,
    }
end

local function ResolveInwardPortWall(rawLx, rawLy)
    -- Elevator ports sit on the outer arms (e.g. (+-650, +-300) or (+-300, +-650))
    -- and face inward along the shorter-magnitude axis toward the hallway centerline.
    if math.abs(rawLx) >= math.abs(rawLy) then
        local ny = (rawLy >= 0.0) and -1.0 or 1.0
        return rawLx, -ny * PORT_WALL_OFFSET_CM, 0.0, ny
    end
    local nx = (rawLx >= 0.0) and -1.0 or 1.0
    return -nx * PORT_WALL_OFFSET_CM, rawLy, nx, 0.0
end

-- Computes exact machine-local port offset { lx, ly, gridZ, nx, ny } from UMachineObject.Inputs
-- Empirical NearBelts verification: Elevator Inputs use 50cm grid units with +X=Forward, +Y=Right.
local function ResolvePortLocalFromInputs(stopObj, idx1, bAddr)
    local inputs, inCount = {}, 0
    local srcName = "Inputs"
    local okInputs, inputsRaw = pcall(function() return stopObj.Inputs end)
    if okInputs and inputsRaw then
        inputs, inCount = ExtractArray(inputsRaw)
    end
    local portVec = inputs[idx1]
    if not portVec then
        local okOut, outRaw = pcall(function() return stopObj.Outputs end)
        if okOut and outRaw then
            local outputs, outCount = ExtractArray(outRaw)
            portVec = outputs[idx1]
            if portVec then
                srcName = "Outputs"
            end
            if inCount == 0 then
                inputs, inCount = outputs, outCount
            end
        end
    end
    if not portVec then
        LogOnce(string.format("%s:noPort:%d", tostring(bAddr), idx1),
            "Step[PortLocal] Shaft 0x%X Port#%d MISSING (Inputs=%d)",
            tonumber(bAddr) or 0, idx1, inCount)
        return nil
    end

    local dimStr = "nil"
    pcall(function()
        local dim = stopObj.MachineDimensions
        if dim then
            dimStr = string.format("(%.1f,%.1f,%.1f)", tonumber(dim.X) or 0, tonumber(dim.Y) or 0, tonumber(dim.Z) or 0)
        end
    end)

    local cx, cy = 0.0, 0.0
    if inCount >= 2 then
        local sx, sy, validN = 0.0, 0.0, 0
        for k = 1, inCount do
            local v = inputs[k]
            if v then
                local vx, vy = 0.0, 0.0
                local okV = pcall(function()
                    vx = tonumber(v.X) or 0.0
                    vy = tonumber(v.Y) or 0.0
                end)
                if okV then
                    sx = sx + vx
                    sy = sy + vy
                    validN = validN + 1
                end
            end
        end
        if validN > 0 then
            cx = sx / validN
            cy = sy / validN
        end
    else
        pcall(function()
            local dim = stopObj.MachineDimensions
            if dim then
                cx = ((tonumber(dim.X) or 1.0) - 1.0) * 0.5
                cy = ((tonumber(dim.Y) or 1.0) - 1.0) * 0.5
            end
        end)
    end

    local px, py, pz = 0.0, 0.0, 0.0
    pcall(function()
        px = tonumber(portVec.X) or 0.0
        py = tonumber(portVec.Y) or 0.0
        pz = tonumber(portVec.Z) or 0.0
    end)

    local rawLx = (px - cx) * GRID_UNIT_CM
    local rawLy = (py - cy) * GRID_UNIT_CM
    local lx, ly, nx, ny = ResolveInwardPortWall(rawLx, rawLy)

    LogOnce(string.format("%s:inp:%d", tostring(bAddr), idx1),
        "Step[PortLocal] Shaft 0x%X Port#%d src=%s n=%d dim=%s raw=(%.1f,%.1f,%.1f) centroid=(%.2f,%.2f) unclamped=(%.1f,%.1f) local=(%.1f,%.1f) n=(%.0f,%.0f)",
        tonumber(bAddr) or 0, idx1, srcName, inCount, dimStr, px, py, pz, cx, cy, rawLx, rawLy, lx, ly, nx, ny)

    return { lx = lx, ly = ly, gridZ = pz, nx = nx, ny = ny }
end

local function RefreshCachedWorldPorts()
    local now = os.clock()
    if (now - LastPortRefresh) < PORT_DATA_PERIOD then
        return
    end
    LastPortRefresh = now

    local worldPorts = {}
    local seenBottom = {}

    for addr, elevActor in pairs(CachedElevActors) do
        if not Core.IsValidObj(elevActor) then
            CachedElevActors[addr] = nil
        else
            local elevObj = GetElevatorObject(elevActor)
            local bottomElev = GetBottomElevator(elevObj)
            if Core.IsValidObj(bottomElev) then
                local bAddr = bottomElev:GetAddress()
                if not seenBottom[bAddr] then
                    seenBottom[bAddr] = true

                    local okCols, colsRaw = pcall(function() return bottomElev.ItemColumns end)
                    local cols, colCount = {}, 0
                    if okCols and colsRaw then
                        cols, colCount = ExtractArray(colsRaw)
                    end
                    if colCount > 0 then
                        local activeCols = {}
                        for idx1 = 1, colCount do
                            local stackElem = cols[idx1]
                            local amt = 0
                            local item = nil
                            if stackElem then
                                pcall(function()
                                    amt = tonumber(stackElem.Amount) or 0
                                    item = stackElem.Item
                                end)
                            end
                            if amt > 0 and Core.IsValidObj(item) then
                                activeCols[#activeCols + 1] = {
                                    Idx1 = idx1,
                                    Item = item,
                                    ItemAddr = item:GetAddress(),
                                    Amount = amt,
                                }
                            end
                        end

                        LogOnce(string.format("%s:cols:%d", tostring(bAddr), #activeCols),
                            "Step[Shaft] 0x%X ItemColumns=%d active=%d",
                            tonumber(bAddr) or 0, colCount, #activeCols)

                        for _, colInfo in ipairs(activeCols) do
                            LogOnce(string.format("%s:col:%d:%s", tostring(bAddr), colInfo.Idx1, tostring(colInfo.ItemAddr)),
                                "Step[Col] Shaft 0x%X col#%d amt=%.0f item=%s (0x%X)",
                                tonumber(bAddr) or 0, colInfo.Idx1, colInfo.Amount,
                                SafeObjName(colInfo.Item), tonumber(colInfo.ItemAddr) or 0)
                        end

                        if #activeCols > 0 then
                            local okStack, stackRaw = pcall(function() return bottomElev.ElevatorStack end)
                            local stack, stackCount = {}, 0
                            if okStack and stackRaw then
                                stack, stackCount = ExtractArray(stackRaw)
                            end
                            if stackCount == 0 then
                                stack = { bottomElev }
                                stackCount = 1
                            end

                            local stopFrames = {}
                            local shaftFrame = nil
                            for sIdx = 1, stackCount do
                                local stopObj = stack[sIdx]
                                if Core.IsValidObj(stopObj) then
                                    local f = GetStopFrameInfo(stopObj)
                                    stopFrames[sIdx] = f
                                    if f and f.HasActor and not shaftFrame then
                                        shaftFrame = f
                                    end
                                end
                            end

                            -- Share the shaft's 3D basis across any stop whose actor wasn't loaded
                            if shaftFrame then
                                for sIdx = 1, stackCount do
                                    local f = stopFrames[sIdx]
                                    if f and not f.HasActor then
                                        f.Fw = shaftFrame.Fw
                                        f.Rt = shaftFrame.Rt
                                        f.Up = shaftFrame.Up
                                        f.Rot = shaftFrame.Rot
                                        f.Yaw = shaftFrame.Yaw
                                        f.InheritedBasis = true
                                    end
                                end
                            end

                            local stepDotUp = nil
                            if stopFrames[1] and stopFrames[2] then
                                local sx = stopFrames[2].Pos.X - stopFrames[1].Pos.X
                                local sy = stopFrames[2].Pos.Y - stopFrames[1].Pos.Y
                                local sz = stopFrames[2].Pos.Z - stopFrames[1].Pos.Z
                                local stepLen = math.sqrt(sx * sx + sy * sy + sz * sz)
                                local u = stopFrames[1].Up
                                stepDotUp = sx * u.X + sy * u.Y + sz * u.Z
                                LogOnce(string.format("%s:step", tostring(bAddr)),
                                    "Step[ShaftStep] 0x%X stop1->stop2=(%.1f,%.1f,%.1f) len=%.1f stepDotUp=%.1f",
                                    tonumber(bAddr) or 0, sx, sy, sz, stepLen, stepDotUp)
                            end

                            for sIdx = 1, stackCount do
                                local f = stopFrames[sIdx]
                                if f then
                                    local d = f.Diag
                                    local dStr = d and string.format("door=%s wig=%s call=%s mesh=[%s]",
                                        FormatLocalPos(d.doorLocal),
                                        FormatLocalPos(d.wigLocal),
                                        FormatLocalPos(d.callLocal),
                                        d.meshDiag or "nil") or "nil"
                                    LogOnce(string.format("%s:stop:%d:%s:%s", tostring(bAddr), sIdx, tostring(f.HasActor), tostring(f.InheritedBasis)),
                                        "Step[StopFrame] Shaft 0x%X stop#%d/%d obj=0x%X actorSrc=%s posSrc=%s inherited=%s pos=(%.1f,%.1f,%.1f) rot=(P=%.1f,Y=%.1f,R=%.1f) fw=(%.2f,%.2f,%.2f) rt=(%.2f,%.2f,%.2f) up=(%.2f,%.2f,%.2f) comps={%s}",
                                        tonumber(bAddr) or 0, sIdx, stackCount, f.StopAddr,
                                        f.ActorSrc, f.PosSrc, tostring(f.InheritedBasis),
                                        f.Pos.X, f.Pos.Y, f.Pos.Z,
                                        f.Rot.Pitch, f.Rot.Yaw, f.Rot.Roll,
                                        f.Fw.X, f.Fw.Y, f.Fw.Z,
                                        f.Rt.X, f.Rt.Y, f.Rt.Z,
                                        f.Up.X, f.Up.Y, f.Up.Z, dStr)
                                end
                            end

                            local bHex = string.format("0x%X", tonumber(bAddr) or 0)
                            LogShaftFullGeometry(bAddr, bHex, bottomElev, stopFrames, stackCount)
                            for _, colInfo in ipairs(activeCols) do
                                local localPort = ResolvePortLocalFromInputs(bottomElev, colInfo.Idx1, bAddr)
                                if localPort then
                                    for sIdx = 1, stackCount do
                                        local frame = stopFrames[sIdx]
                                        if frame then
                                            local lz = PANEL_Z_ABOVE_STOP + (localPort.gridZ * GRID_UNIT_CM)
                                            local wx = frame.Pos.X + frame.Fw.X * localPort.lx + frame.Rt.X * localPort.ly + frame.Up.X * lz
                                            local wy = frame.Pos.Y + frame.Fw.Y * localPort.lx + frame.Rt.Y * localPort.ly + frame.Up.Y * lz
                                            local wz = frame.Pos.Z + frame.Fw.Z * localPort.lx + frame.Rt.Z * localPort.ly + frame.Up.Z * lz
                                            local wnx = frame.Fw.X * localPort.nx + frame.Rt.X * localPort.ny
                                            local wny = frame.Fw.Y * localPort.nx + frame.Rt.Y * localPort.ny
                                            local wnz = frame.Fw.Z * localPort.nx + frame.Rt.Z * localPort.ny

                                            LogOnce(string.format("%s:wp:%d:%d", tostring(bAddr), colInfo.Idx1, sIdx),
                                                "Step[WorldPort] Shaft %s col#%d stop#%d/%d item=%s lz=%.1f wallDist=%.1f worldPos=(%.1f,%.1f,%.1f) n=(%.2f,%.2f,%.2f) stopPos=(%.1f,%.1f,%.1f)",
                                                bHex, colInfo.Idx1, sIdx, stackCount, SafeObjName(colInfo.Item),
                                                lz, math.sqrt(localPort.lx * localPort.lx + localPort.ly * localPort.ly),
                                                wx, wy, wz, wnx, wny, wnz, frame.Pos.X, frame.Pos.Y, frame.Pos.Z)

                                            worldPorts[#worldPorts + 1] = {
                                                ShaftHex = bHex,
                                                ColIdx = colInfo.Idx1,
                                                StopIdx = sIdx,
                                                X = wx,
                                                Y = wy,
                                                Z = wz,
                                                Nx = wnx,
                                                Ny = wny,
                                                Nz = wnz,
                                                Ux = frame.Up.X,
                                                Uy = frame.Up.Y,
                                                Uz = frame.Up.Z,
                                                Item = colInfo.Item,
                                                ItemAddr = colInfo.ItemAddr,
                                            }
                                        end
                                    end
                                end
                            end
                        end
                    else
                        LogOnce(string.format("%s:nocols", tostring(bAddr)),
                            "Step[Shaft] 0x%X has ItemColumns=0", tonumber(bAddr) or 0)
                    end
                end
            else
                LogOnce("err:noBottom:" .. tostring(addr),
                    "Step[Shaft] AElevator 0x%X returned nil BottomElevator", tonumber(addr) or 0)
            end
        end
    end

    CachedWorldPorts = worldPorts
    if #worldPorts > 0 or LoggedShafts["hadPorts"] then
        if #worldPorts > 0 then LoggedShafts["hadPorts"] = true end
        LogOnce("worldPorts:" .. tostring(#worldPorts),
            "Step[WorldPorts] Cached active port entries=%d", #worldPorts)
    end
end

local function UpdateElevatorPortIcons()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then
        LogOnce("err:pc", "Step[Render] LocalPlayerController invalid")
        return
    end

    RefreshElevatorActorCache(false)
    RefreshCachedWorldPorts()

    local camMgr = pc.PlayerCameraManager
    local mathLib = Core.GetCDO(PATHS.KismetMathLib)
    if not Core.IsValidObj(mathLib) then
        LogOnce("err:mathLib", "Step[Render] KismetMathLibrary invalid")
        return
    end

    local camLoc = nil
    local camRot = nil
    if Core.IsValidObj(camMgr) then
        pcall(function()
            local loc = camMgr:GetCameraLocation()
            if loc then
                camLoc = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }
            end
            local cr = camMgr:GetCameraRotation()
            if cr then
                camRot = { Pitch = tonumber(cr.Pitch) or 0.0, Yaw = tonumber(cr.Yaw) or 0.0, Roll = tonumber(cr.Roll) or 0.0 }
            end
        end)
    end
    if not camLoc and Core.IsValidObj(pc.Pawn) then
        pcall(function()
            local loc = pc.Pawn:K2_GetActorLocation()
            if loc then
                camLoc = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = (tonumber(loc.Z) or 0.0) + 60.0 }
            end
        end)
    end
    if not camLoc then
        LogOnce("err:camLoc", "Step[Render] Camera location unavailable")
        return
    end

    local count = 0
    local nearest = nil
    for _, wp in ipairs(CachedWorldPorts) do
        if Core.IsValidObj(wp.Item) then
            local dx = camLoc.X - wp.X
            local dy = camLoc.Y - wp.Y
            local dz = camLoc.Z - wp.Z
            local distSq = dx * dx + dy * dy + dz * dz
            if distSq <= MAX_VIEW_DIST_SQ then
                count = count + 1
                local entry = GetOrCreateIconActor(pc, count)
                if entry then
                    local appliedRot = nil
                    local okSet, errSet = pcall(function()
                        if entry.LastItemAddr ~= wp.ItemAddr then
                            entry.ItemWidget:SetItem(wp.Item)
                            entry.LastItemAddr = wp.ItemAddr
                        end
                        -- Face the bright front (+X) side toward the outward wall normal
                        local rot = mathLib:MakeRotFromXZ(
                            { X = wp.Nx, Y = wp.Ny, Z = wp.Nz },
                            { X = wp.Ux, Y = wp.Uy, Z = wp.Uz }
                        )
                        appliedRot = rot
                        entry.Comp:K2_SetWorldLocationAndRotation(
                            { X = wp.X, Y = wp.Y, Z = wp.Z },
                            rot,
                            false,
                            {},
                            true
                        )
                        entry.Comp:SetVisibility(true, false)
                    end)
                    if not okSet then
                        LogOnce("err:set:" .. tostring(count),
                            "Step[Render] Apply error icon#%d: %s", count, tostring(errSet))
                    end
                    if not nearest or distSq < nearest.distSq then
                        local frontDot = dx * wp.Nx + dy * wp.Ny + dz * wp.Nz
                        local upDot = dx * wp.Ux + dy * wp.Uy + dz * wp.Uz
                        -- In Unreal left-handed coords, +Y = Z x X
                        local rx = wp.Uy * wp.Nz - wp.Uz * wp.Ny
                        local ry = wp.Uz * wp.Nx - wp.Ux * wp.Nz
                        local rz = wp.Ux * wp.Ny - wp.Uy * wp.Nx
                        local rightDot = dx * rx + dy * ry + dz * rz
                        nearest = {
                            distSq = distSq,
                            wp = wp,
                            entry = entry,
                            rot = appliedRot,
                            frontDot = frontDot,
                            rightDot = rightDot,
                            upDot = upDot,
                        }
                    end
                end
            end
        end
    end

    if count > 0 or #CachedWorldPorts > 0 then
        LogOnce(string.format("vis:%d:%d", count, #CachedWorldPorts),
            "Step[Render] Visible in range (<=30m): %d / %d", count, #CachedWorldPorts)
    end

    if nearest and nearest.distSq < (1500.0 * 1500.0) then
        local nw = nearest.wp
        local nearKey = string.format("near:%s:%d:%d", tostring(nw.ShaftHex), nw.ColIdx, nw.StopIdx)
        if not LoggedShafts[nearKey] then
            LoggedShafts[nearKey] = true
            local actLocStr = "nil"
            local visStr = "nil"
            pcall(function()
                local cl = nearest.entry.Comp:K2_GetComponentLocation()
                if cl then
                    actLocStr = string.format("(%.1f,%.1f,%.1f)", tonumber(cl.X) or 0, tonumber(cl.Y) or 0, tonumber(cl.Z) or 0)
                end
                if nearest.entry.Comp.IsVisible then
                    visStr = tostring(nearest.entry.Comp:IsVisible())
                end
            end)
            local rotP = nearest.rot and (tonumber(nearest.rot.Pitch) or 0) or 0
            local rotY = nearest.rot and (tonumber(nearest.rot.Yaw) or 0) or 0
            local rotR = nearest.rot and (tonumber(nearest.rot.Roll) or 0) or 0
            local cRotStr = camRot and string.format("(P=%.1f,Y=%.1f,R=%.1f)", camRot.Pitch, camRot.Yaw, camRot.Roll) or "nil"
            Core.Log(string.format(
                "[ElevatorLabels] Step[NearestPort] %s col#%d stop#%d item=%s dist=%.1f rel=(front=%.1f,right=%.1f,up=%.1f) target=(%.1f,%.1f,%.1f) compLoc=%s vis=%s rot=(P=%.1f,Y=%.1f,R=%.1f) n=(%.2f,%.2f,%.2f) u=(%.2f,%.2f,%.2f) cam=(%.1f,%.1f,%.1f) camRot=%s",
                tostring(nw.ShaftHex), nw.ColIdx, nw.StopIdx, SafeObjName(nw.Item),
                math.sqrt(nearest.distSq), nearest.frontDot, nearest.rightDot, nearest.upDot,
                nw.X, nw.Y, nw.Z, actLocStr, visStr, rotP, rotY, rotR,
                nw.Nx, nw.Ny, nw.Nz, nw.Ux, nw.Uy, nw.Uz,
                camLoc.X, camLoc.Y, camLoc.Z, cRotStr))
        end
    end

    for i = count + 1, #IconPool do
        local entry = IconPool[i]
        if entry and Core.IsValidObj(entry.Comp) then
            pcall(function() entry.Comp:SetVisibility(false, false) end)
        end
    end
end

local function StartPoll()
    if PollActive then return end
    PollActive = true
    local function Tick()
        local okTick, errTick = pcall(UpdateElevatorPortIcons)
        if not okTick then
            LogOnce("err:tick:" .. tostring(errTick), "Step[Tick] Unhandled error: %s", tostring(errTick))
        end
        ExecuteInGameThreadWithDelay(33, Tick)
    end
    ExecuteInGameThreadWithDelay(33, Tick)
end

function Feature.Init()
    StartPoll()
    Core.Log("[ElevatorLabels] Initialized (3D WidgetComponent ItemColumns port icons).")
end

function Feature.OnClientRestart()
    DestroyIconPool()
    CachedElevActors = {}
    CachedObjToActor = {}
    CachedWorldPorts = {}
    LoggedShafts = {}
    LastElevatorScan = -10.0
    LastPortRefresh = -10.0
end

function Feature.PruneCaches()
    for i, entry in ipairs(IconPool) do
        if not entry or not Core.IsValidObj(entry.Actor) then
            IconPool[i] = nil
        end
    end
end

return Feature
