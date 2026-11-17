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
    Transparent = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 },
}

local GRID_UNIT_CM         = 25.0   -- UMachineObject.Inputs uses 25 cm sub-grid units
local DEFAULT_WALL_DIST    = 267.0  -- cm outward from module center (just outside +-264cm hull)
local PANEL_Z_ABOVE_STOP   = 276.0  -- cm above stopPos.Z (centered on blank gray plate above purple collar)
local MAX_VIEW_DIST_SQ     = 3000.0 * 3000.0
local ICON_PIXEL_SIZE      = 64.0
local ICON_WORLD_SCALE     = 1.10   -- ~70 cm icon centered inside ~110x110 cm blank gray plate
local ELEVATOR_SCAN_PERIOD = 1.5
local PORT_DATA_PERIOD     = 0.25

local CachedElevActors = {} -- addr -> AElevator
local CachedWorldPorts = {} -- list of { X, Y, Z, Nx, Ny, Nz, Ux, Uy, Uz, Item, ItemAddr }
local IconPool         = {} -- idx -> { Actor, Comp, ItemWidget, LastItemAddr }
local LastElevatorScan = -10.0
local LastPortRefresh  = -10.0
local LoggedShafts     = {}
local PollActive       = false

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
    if not Core.IsValidObj(compCls) then return nil end

    local actor = Core.SpawnActor(pc, PATHS.ActorClass, { X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    if not Core.IsValidObj(actor) then return nil end

    local xform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local okC, comp = pcall(function()
        return actor:AddComponentByClass(compCls, false, xform, false)
    end)
    if not okC or not Core.IsValidObj(comp) then
        pcall(function() actor:K2_DestroyActor() end)
        return nil
    end

    pcall(function() actor:K2_SetRootComponent(comp) end)

    local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, pc, pc)
    if not Core.IsValidObj(itemW) then
        pcall(function() actor:K2_DestroyActor() end)
        return nil
    end

    pcall(function()
        itemW.TooltipEnabled = false
        itemW:SetIconSize(ICON_PIXEL_SIZE)
        itemW:SetVisibility(0)
        comp:SetWidgetSpace(0) -- World space
        comp:SetDrawSize({ X = ICON_PIXEL_SIZE, Y = ICON_PIXEL_SIZE })
        comp:SetDrawAtDesiredSize(true)
        comp:SetPivot({ X = 0.5, Y = 0.5 })
        comp:SetTwoSided(true)
        comp:SetBackgroundColor(COLORS.Transparent)
        comp:SetWidget(itemW)
        comp:SetWorldScale3D({ X = ICON_WORLD_SCALE, Y = ICON_WORLD_SCALE, Z = ICON_WORLD_SCALE })
        comp:SetVisibility(false, false)
    end)

    entry = {
        Actor = actor,
        Comp = comp,
        ItemWidget = itemW,
        LastItemAddr = nil,
    }
    IconPool[idx] = entry
    return entry
end

local function RefreshElevatorActorCache(force)
    local now = os.clock()
    if not force and (now - LastElevatorScan) < ELEVATOR_SCAN_PERIOD then
        return
    end
    LastElevatorScan = now

    local nextMap = {}
    local ok, actors = pcall(FindAllOf, "Elevator")
    if ok and actors then
        for _, actor in ipairs(actors) do
            if Core.IsValidObj(actor) then
                nextMap[actor:GetAddress()] = actor
            end
        end
    end
    CachedElevActors = nextMap
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
    if not Core.IsValidObj(simObj) then return nil end
    local actor = nil
    pcall(function()
        local actors = ExtractArray(simObj.Actors)
        if Core.IsValidObj(actors[1]) then
            actor = actors[1]
        end
    end)
    return actor
end

local function SafeCompZ(comp)
    if not Core.IsValidObj(comp) or not comp.K2_GetComponentLocation then return nil end
    local z = nil
    pcall(function()
        local loc = comp:K2_GetComponentLocation()
        if loc and type(loc.Z) == "number" then
            z = loc.Z
        end
    end)
    return z
end

local function GetStopFrameInfo(stopObj)
    local actor = GetActorFromSimObj(stopObj)
    local pos = nil
    local yaw = 0.0
    local fw = { X = 1.0, Y = 0.0, Z = 0.0 }
    local rt = { X = 0.0, Y = 1.0, Z = 0.0 }
    local up = { X = 0.0, Y = 0.0, Z = 1.0 }
    local diag = nil

    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc then
            pos = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }
        end
        pcall(function()
            local rot = actor:GetActorRotation()
            if rot and type(rot.Yaw) == "number" then
                yaw = rot.Yaw
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
        diag = {
            doorZ = SafeCompZ(actor.BPC_Door),
            wigZ = SafeCompZ(actor.Widget),
            callZ = SafeCompZ(actor.CallInteraction),
        }
    end

    if not pos then
        local okM, mx, my, mz, mYaw = pcall(StationData.GetMachineWorldPosAndYaw, stopObj, nil)
        if okM and type(mx) == "number" then
            pos = { X = mx, Y = my or 0.0, Z = mz or 0.0 }
            yaw = mYaw or 0.0
            local rad = math.rad(yaw)
            fw = { X = math.cos(rad), Y = math.sin(rad), Z = 0.0 }
            rt = { X = -math.sin(rad), Y = math.cos(rad), Z = 0.0 }
        end
    end
    if not pos then
        local worldUtils = Core.GetCDO(PATHS.WorldUtilsCDO)
        if Core.IsValidObj(worldUtils) and worldUtils.GetObjectWorldLocation then
            local okLoc, loc = pcall(function() return worldUtils:GetObjectWorldLocation(stopObj) end)
            if okLoc and loc then
                pos = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }
            end
        end
    end
    if not pos then return nil end

    return {
        Pos = pos,
        Yaw = yaw,
        Fw = fw,
        Rt = rt,
        Up = up,
        Actor = actor,
        Diag = diag,
    }
end

local function SnapAxisNormal(dx, dy)
    if math.abs(dx) >= math.abs(dy) then
        return (dx >= 0.0 and 1.0 or -1.0), 0.0
    end
    return 0.0, (dy >= 0.0 and 1.0 or -1.0)
end

-- Computes exact machine-local port offset { lx, ly, gridZ, nx, ny } from UMachineObject.Inputs
-- Empirical UE4SS log verification: Inputs uses 25cm sub-grid units with +X=Forward, -Y=Right.
local function ResolvePortLocalFromInputs(stopObj, idx1, bAddr)
    local inputs, inCount = {}, 0
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
            if inCount == 0 then
                inputs, inCount = outputs, outCount
            end
        end
    end
    if not portVec then return nil end

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
    local rawLy = -(py - cy) * GRID_UNIT_CM
    local nx, ny = SnapAxisNormal(rawLx, rawLy)
    local lx = (nx ~= 0.0) and (nx * DEFAULT_WALL_DIST) or rawLx
    local ly = (ny ~= 0.0) and (ny * DEFAULT_WALL_DIST) or rawLy

    if not LoggedShafts[bAddr .. ":inp" .. idx1] then
        LoggedShafts[bAddr .. ":inp" .. idx1] = true
        Core.Log(string.format(
            "[ElevatorLabels] Port#%d Inputs raw=(%.1f,%.1f,%.1f) centroid=(%.2f,%.2f) local=(%.1f,%.1f) n=(%.0f,%.0f)",
            idx1, px, py, pz, cx, cy, lx, ly, nx, ny))
    end

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

                        if not LoggedShafts[bAddr .. ":cols"] then
                            LoggedShafts[bAddr .. ":cols"] = true
                            Core.Log(string.format("[ElevatorLabels] Shaft 0x%X: ItemColumns=%d active=%d",
                                tonumber(bAddr) or 0, colCount, #activeCols))
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
                            for sIdx = 1, stackCount do
                                local stopObj = stack[sIdx]
                                if Core.IsValidObj(stopObj) then
                                    stopFrames[sIdx] = GetStopFrameInfo(stopObj)
                                end
                            end

                            local stepZ = nil
                            if stopFrames[1] and stopFrames[2] then
                                stepZ = stopFrames[2].Pos.Z - stopFrames[1].Pos.Z
                            end

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

                                            if not LoggedShafts[bAddr .. ":frame"] then
                                                LoggedShafts[bAddr .. ":frame"] = true
                                                local d = frame.Diag
                                                local dStr = d and string.format("doorZ=%s wigZ=%s callZ=%s",
                                                    d.doorZ and string.format("%.1f", d.doorZ) or "nil",
                                                    d.wigZ and string.format("%.1f", d.wigZ) or "nil",
                                                    d.callZ and string.format("%.1f", d.callZ) or "nil") or "nil"
                                                Core.Log(string.format(
                                                    "[ElevatorLabels] Shaft 0x%X frame: stopZ=%.1f yaw=%.1f panelZ=%.1f stepZ=%s [%s]",
                                                    tonumber(bAddr) or 0, frame.Pos.Z, frame.Yaw, wz,
                                                    stepZ and string.format("%.1f", stepZ) or "nil", dStr))
                                            end

                                            worldPorts[#worldPorts + 1] = {
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
                    end
                end
            end
        end
    end

    CachedWorldPorts = worldPorts
end

local function UpdateElevatorPortIcons()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    RefreshElevatorActorCache(false)
    RefreshCachedWorldPorts()

    local camMgr = pc.PlayerCameraManager
    local mathLib = Core.GetCDO(PATHS.KismetMathLib)
    if not Core.IsValidObj(mathLib) then return end

    local camLoc = nil
    if Core.IsValidObj(camMgr) then
        pcall(function()
            local loc = camMgr:GetCameraLocation()
            if loc then
                camLoc = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }
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
    if not camLoc then return end

    local count = 0
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
                    pcall(function()
                        if entry.LastItemAddr ~= wp.ItemAddr then
                            entry.ItemWidget:SetItem(wp.Item)
                            entry.LastItemAddr = wp.ItemAddr
                        end
                        -- Face the bright front (+X) side toward the outward wall normal
                        local rot = mathLib:MakeRotFromXZ(
                            { X = wp.Nx, Y = wp.Ny, Z = wp.Nz },
                            { X = wp.Ux, Y = wp.Uy, Z = wp.Uz }
                        )
                        entry.Comp:K2_SetWorldLocationAndRotation(
                            { X = wp.X, Y = wp.Y, Z = wp.Z },
                            rot,
                            false,
                            {},
                            true
                        )
                        entry.Comp:SetVisibility(true, false)
                    end)
                    if not LoggedShafts["first3d"] then
                        LoggedShafts["first3d"] = true
                        Core.Log(string.format(
                            "[ElevatorLabels] First 3D port icon active: pos=(%.1f,%.1f,%.1f) n=(%.2f,%.2f) totalPorts=%d",
                            wp.X, wp.Y, wp.Z, wp.Nx, wp.Ny, #CachedWorldPorts))
                    end
                end
            end
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
        pcall(UpdateElevatorPortIcons)
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
end

function Feature.PruneCaches()
    for i, entry in ipairs(IconPool) do
        if not entry or not Core.IsValidObj(entry.Actor) then
            IconPool[i] = nil
        end
    end
end

return Feature
