-- Eqol Feature: Elevator Port Item Icons
-- Displays the item icon from each populated UElevatorObject.ItemColumns slot
-- on the blank panel directly above the matching conveyor port across every
-- stacked elevator module in that shaft (above and below the feeder floor).

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "ElevatorLabels",
}

local PATHS = {
    WBPItemClass     = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    CanvasPanelClass = "/Script/UMG.CanvasPanel",
    WidgetLayoutLib  = "/Script/UMG.Default__WidgetLayoutLibrary",
    WorldUtilsCDO    = "/Script/MainSequence.Default__WorldUtils",
}

local MAX_RENDER_DIST_SQ   = 4000.0 * 4000.0
local MIN_FACING_DOT       = 15.0
local DEFAULT_WALL_DIST    = 266.0
local PANEL_ABOVE_BELT_Z   = 112.0
local FALLBACK_PANEL_Z     = 160.0
local ELEVATOR_SCAN_PERIOD = 1.5
local PORT_DATA_PERIOD     = 0.20

local CachedElevActors = {} -- addr -> AElevator
local CachedWorldPorts = {} -- list of { X, Y, Z, Nx, Ny, Item, ItemAddr }
local LastElevatorScan = -10.0
local LastPortRefresh  = -10.0
local LastHudScan      = -10.0
local HudOverlays      = {} -- hudAddr -> { Hud, PC, Outer, Canvas, Pool = {} }
local LoggedShafts     = {} -- bottomAddr -> true
local HooksRegistered  = false

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

local function GetSimObjWorldPos(simObj)
    local actor = GetActorFromSimObj(simObj)
    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc then
            local yaw = 0.0
            pcall(function()
                local rot = actor:GetActorRotation()
                if rot and type(rot.Yaw) == "number" then
                    yaw = rot.Yaw
                end
            end)
            return { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }, yaw, actor
        end
    end

    local worldUtils = Core.GetCDO(PATHS.WorldUtilsCDO)
    if Core.IsValidObj(worldUtils) and worldUtils.GetObjectWorldLocation then
        local okLoc, loc = pcall(function() return worldUtils:GetObjectWorldLocation(simObj) end)
        if okLoc and loc then
            return { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }, 0.0, nil
        end
    end
    return nil, 0.0, nil
end

local function RotateXYDeg(x, y, deg)
    local rad = math.rad(deg or 0.0)
    local c = math.cos(rad)
    local s = math.sin(rad)
    return x * c - y * s, x * s + y * c
end

local function RotateGridSteps(dx, dy, gridRot)
    local r = (tonumber(gridRot) or 0) % 4
    if r == 1 then return -dy, dx end
    if r == 2 then return -dx, -dy end
    if r == 3 then return dy, -dx end
    return dx, dy
end

local function SnapAxisNormal(dx, dy)
    if math.abs(dx) >= math.abs(dy) then
        return (dx >= 0.0 and 1.0 or -1.0), 0.0
    end
    return 0.0, (dy >= 0.0 and 1.0 or -1.0)
end

-- Resolves port `idx1` (1-based) in stop-actor local space: { lx, ly, lz, nx, ny }
local function ResolvePortLocalOffset(stack, stackCount, idx1, bottomAddr)
    -- Pass 1: derive exact local side, tangent offset, and Z from any connected conveyor/machine in the shaft
    for sIdx = 1, stackCount do
        local stopObj = stack[sIdx]
        if Core.IsValidObj(stopObj) then
            local stopPos, stopYaw, stopActor = GetSimObjWorldPos(stopObj)
            if stopPos then
                local connObj = nil
                local okIn, inRaw = pcall(function() return stopObj.InputMachines end)
                if okIn and inRaw then
                    local inMach = ExtractArray(inRaw)
                    if Core.IsValidObj(inMach[idx1]) then
                        connObj = inMach[idx1]
                    end
                end
                if not Core.IsValidObj(connObj) then
                    local okOut, outRaw = pcall(function() return stopObj.OutputMachines end)
                    if okOut and outRaw then
                        local outMach = ExtractArray(outRaw)
                        if Core.IsValidObj(outMach[idx1]) then
                            connObj = outMach[idx1]
                        end
                    end
                end

                if Core.IsValidObj(connObj) then
                    local connPos = GetSimObjWorldPos(connObj)
                    if connPos then
                        local dxW = connPos.X - stopPos.X
                        local dyW = connPos.Y - stopPos.Y
                        local dz  = connPos.Z - stopPos.Z
                        local rx, ry = RotateXYDeg(dxW, dyW, -stopYaw)
                        local nx, ny = SnapAxisNormal(rx, ry)

                        -- Place icon flush on the outer wall face above the port collar,
                        -- using connected machine's axis-projected distance or actor half-extent.
                        local axisDist = math.abs(nx) * math.abs(rx) + math.abs(ny) * math.abs(ry)
                        local wallDist = DEFAULT_WALL_DIST
                        if axisDist > 260.0 and axisDist < 420.0 then
                            wallDist = math.max(245.0, math.min(295.0, axisDist - 42.0))
                        elseif Core.IsValidObj(stopActor) and stopActor.GetActorBounds then
                            local okB, _, ext = pcall(function()
                                local o = { X = 0.0, Y = 0.0, Z = 0.0 }
                                local e = { X = 0.0, Y = 0.0, Z = 0.0 }
                                stopActor:GetActorBounds(false, o, e)
                                return o, e
                            end)
                            if okB and ext then
                                local minXY = math.min(tonumber(ext.X) or 0.0, tonumber(ext.Y) or 0.0)
                                if minXY >= 200.0 and minXY <= 320.0 then
                                    wallDist = minXY + 4.0
                                end
                            end
                        end

                        local lx = (nx ~= 0.0) and (nx * wallDist) or rx
                        local ly = (ny ~= 0.0) and (ny * wallDist) or ry
                        local lz = dz + PANEL_ABOVE_BELT_Z

                        if not LoggedShafts[bottomAddr .. ":c" .. idx1] then
                            LoggedShafts[bottomAddr .. ":c" .. idx1] = true
                            Core.Log(string.format(
                                "[ElevatorLabels] Shaft port#%d calibrated from belt: delta=(%.1f,%.1f,%.1f) local=(%.1f,%.1f,%.1f) n=(%.0f,%.0f)",
                                idx1, dxW, dyW, dz, lx, ly, lz, nx, ny))
                        end

                        return { lx = lx, ly = ly, lz = lz, nx = nx, ny = ny }
                    end
                end
            end
        end
    end

    -- Pass 2: fallback to UMachineObject.Inputs / MachineDimensions when no belt is currently attached
    local refStop = nil
    for sIdx = 1, stackCount do
        if Core.IsValidObj(stack[sIdx]) then
            refStop = stack[sIdx]
            break
        end
    end
    if not Core.IsValidObj(refStop) then return nil end

    local inputs, inCount = {}, 0
    local okInputs, inputsRaw = pcall(function() return refStop.Inputs end)
    if okInputs and inputsRaw then
        inputs, inCount = ExtractArray(inputsRaw)
    end
    local portVec = inputs[idx1]
    if not portVec then
        local okOutputs, outputsRaw = pcall(function() return refStop.Outputs end)
        if okOutputs and outputsRaw then
            local outputs = ExtractArray(outputsRaw)
            portVec = outputs[idx1]
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
            local dim = refStop.MachineDimensions
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
    local rawDx = px - cx
    local rawDy = py - cy
    local gridRot = 0
    pcall(function()
        if refStop.GridTransform then
            gridRot = tonumber(refStop.GridTransform.GridRotation) or 0
        end
    end)
    local gx, gy = RotateGridSteps(rawDx, rawDy, gridRot)
    local _, refYaw = GetSimObjWorldPos(refStop)
    local lx, ly = RotateXYDeg(gx * 100.0, gy * 100.0, -refYaw)
    local nx, ny = SnapAxisNormal(lx, ly)
    local wallDist = DEFAULT_WALL_DIST
    local fx = (nx ~= 0.0) and (nx * wallDist) or lx
    local fy = (ny ~= 0.0) and (ny * wallDist) or ly
    local fz = (pz * 100.0) + FALLBACK_PANEL_Z

    if not LoggedShafts[bottomAddr .. ":f" .. idx1] then
        LoggedShafts[bottomAddr .. ":f" .. idx1] = true
        Core.Log(string.format(
            "[ElevatorLabels] Shaft port#%d fallback from Inputs: raw=(%.1f,%.1f,%.1f) local=(%.1f,%.1f,%.1f) n=(%.0f,%.0f)",
            idx1, rawDx, rawDy, pz, fx, fy, fz, nx, ny))
    end

    return { lx = fx, ly = fy, lz = fz, nx = nx, ny = ny }
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

                            for _, colInfo in ipairs(activeCols) do
                                local localPort = ResolvePortLocalOffset(stack, stackCount, colInfo.Idx1, bAddr)
                                if localPort then
                                    for sIdx = 1, stackCount do
                                        local stopObj = stack[sIdx]
                                        local stopPos, stopYaw = GetSimObjWorldPos(stopObj)
                                        if stopPos then
                                            local wxOff, wyOff = RotateXYDeg(localPort.lx, localPort.ly, stopYaw)
                                            local wnx, wny = RotateXYDeg(localPort.nx, localPort.ny, stopYaw)
                                            worldPorts[#worldPorts + 1] = {
                                                X = stopPos.X + wxOff,
                                                Y = stopPos.Y + wyOff,
                                                Z = stopPos.Z + localPort.lz,
                                                Nx = wnx,
                                                Ny = wny,
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

local function CollectVisibleElevatorPorts(camLoc)
    RefreshCachedWorldPorts()
    local ports = {}
    for _, wp in ipairs(CachedWorldPorts) do
        if Core.IsValidObj(wp.Item) then
            local toCamX = camLoc.X - wp.X
            local toCamY = camLoc.Y - wp.Y
            local toCamZ = camLoc.Z - wp.Z
            local distSq = toCamX * toCamX + toCamY * toCamY + toCamZ * toCamZ
            local facingDot = toCamX * wp.Nx + toCamY * wp.Ny

            if distSq <= MAX_RENDER_DIST_SQ and facingDot >= MIN_FACING_DOT then
                ports[#ports + 1] = {
                    X = wp.X,
                    Y = wp.Y,
                    Z = wp.Z,
                    Dist = math.sqrt(distSq),
                    Item = wp.Item,
                    ItemAddr = wp.ItemAddr,
                }
            end
        end
    end
    return ports
end

local function EnsureHudOverlay(hud)
    if not Core.IsValidObj(hud) then return nil end
    local addr = hud:GetAddress()
    local st = HudOverlays[addr]
    if st and Core.IsValidObj(st.Canvas) then
        return st
    end

    local mainOverlay = hud.MainOverlay
    if not Core.IsValidObj(mainOverlay) then return nil end

    local outer = Core.GetWidgetOuter(mainOverlay)
    local pc = Core.GetLocalPlayerController()
    local canvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    if not Core.IsValidObj(canvas) then return nil end

    local slot = mainOverlay:AddChildToOverlay(canvas)
    if Core.IsValidObj(slot) then
        pcall(function()
            slot:SetHorizontalAlignment(0) -- Fill
            slot:SetVerticalAlignment(0)   -- Fill
        end)
    end
    pcall(function() canvas:SetVisibility(3) end) -- HitTestInvisible

    st = {
        Hud = hud,
        PC = pc,
        Outer = outer,
        Canvas = canvas,
        Pool = {},
    }
    HudOverlays[addr] = st
    return st
end

local function HideAllPool(st)
    for _, entry in ipairs(st.Pool) do
        if Core.IsValidObj(entry.ItemWidget) then
            pcall(function() entry.ItemWidget:SetVisibility(1) end)
        end
    end
end

local function GetOrCreatePoolEntry(st, idx)
    local entry = st.Pool[idx]
    if entry and Core.IsValidObj(entry.ItemWidget) and Core.IsValidObj(entry.Slot) then
        return entry
    end

    if not Core.IsValidObj(st.PC) then
        st.PC = Core.GetLocalPlayerController()
    end
    local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, st.Hud, st.PC)
    if not Core.IsValidObj(itemW) then return nil end

    pcall(function()
        itemW.TooltipEnabled = false
        itemW:SetVisibility(1)
        itemW:SetIconSize(48.0)
    end)

    local cSlot = st.Canvas:AddChildToCanvas(itemW)
    if not Core.IsValidObj(cSlot) then return nil end

    pcall(function()
        cSlot:SetAutoSize(true)
        cSlot:SetAlignment({ X = 0.5, Y = 0.5 })
        cSlot:SetZOrder(25)
    end)

    entry = {
        ItemWidget = itemW,
        Slot = cSlot,
        LastItemAddr = nil,
        LastSize = 48,
    }
    st.Pool[idx] = entry
    return entry
end

local function UpdateElevatorPortIcons()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    RefreshElevatorActorCache(false)

    if next(HudOverlays) == nil then
        local now = os.clock()
        if now - LastHudScan >= 2.0 then
            LastHudScan = now
            local okHud, hud = pcall(FindFirstOf, "WBP_CharacterHUD_C")
            if okHud and Core.IsValidObj(hud) then
                EnsureHudOverlay(hud)
            end
        end
    end

    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    local menuOpen = false
    if Core.IsValidObj(widgetSub) and Core.IsValidObj(widgetSub.CurrentWindow) then
        menuOpen = true
    end

    if menuOpen then
        for addr, st in pairs(HudOverlays) do
            if Core.IsValidObj(st.Hud) and Core.IsValidObj(st.Canvas) then
                HideAllPool(st)
            else
                HudOverlays[addr] = nil
            end
        end
        return
    end

    local camLoc = nil
    pcall(function()
        if Core.IsValidObj(pc.PlayerCameraManager) then
            local loc = pc.PlayerCameraManager:GetCameraLocation()
            if loc then
                camLoc = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = tonumber(loc.Z) or 0.0 }
            end
        end
    end)
    if not camLoc and Core.IsValidObj(pc.Pawn) then
        pcall(function()
            local loc = pc.Pawn:K2_GetActorLocation()
            if loc then
                camLoc = { X = tonumber(loc.X) or 0.0, Y = tonumber(loc.Y) or 0.0, Z = (tonumber(loc.Z) or 0.0) + 60.0 }
            end
        end)
    end
    if not camLoc then return end

    local layoutLib = Core.GetCDO(PATHS.WidgetLayoutLib)
    if not Core.IsValidObj(layoutLib) then return end

    local ports = CollectVisibleElevatorPorts(camLoc)

    for addr, st in pairs(HudOverlays) do
        if not (Core.IsValidObj(st.Hud) and Core.IsValidObj(st.Canvas)) then
            HudOverlays[addr] = nil
        else
            local okVis, hudVis = pcall(function() return st.Hud:GetVisibility() end)
            if okVis and hudVis ~= 0 and hudVis ~= 3 and hudVis ~= 4 then
                HideAllPool(st)
            else
                local used = 0
                for _, p in ipairs(ports) do
                    local screenPos = { X = 0.0, Y = 0.0 }
                    local okProj, projected = pcall(function()
                        return layoutLib:ProjectWorldLocationToWidgetPosition(
                            pc,
                            { X = p.X, Y = p.Y, Z = p.Z },
                            screenPos,
                            false
                        )
                    end)
                    if okProj and projected and screenPos then
                        used = used + 1
                        local entry = GetOrCreatePoolEntry(st, used)
                        if entry then
                            local iconPx = math.floor(math.max(24, math.min(72, 19500.0 / math.max(180.0, p.Dist))))
                            if entry.LastItemAddr ~= p.ItemAddr then
                                pcall(function() entry.ItemWidget:SetItem(p.Item) end)
                                entry.LastItemAddr = p.ItemAddr
                            end
                            if math.abs((entry.LastSize or 0) - iconPx) >= 2 then
                                pcall(function() entry.ItemWidget:SetIconSize(iconPx) end)
                                entry.LastSize = iconPx
                            end
                            pcall(function()
                                entry.Slot:SetPosition({ X = screenPos.X, Y = screenPos.Y })
                                entry.ItemWidget:SetVisibility(3) -- HitTestInvisible
                            end)
                        end
                    end
                end

                for i = used + 1, #st.Pool do
                    local entry = st.Pool[i]
                    if entry and Core.IsValidObj(entry.ItemWidget) then
                        pcall(function() entry.ItemWidget:SetVisibility(1) end)
                    end
                end
            end
        end
    end
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        Feature.RegisterHooks()
        if Core.IsValidObj(hud) then
            EnsureHudOverlay(hud)
        end
    end,
}

function Feature.RegisterHooks()
    if HooksRegistered then return end
    HooksRegistered = true

    Core.TryRegisterHook(
        "ElevatorLabels_HUDConstruct",
        "/Game/Blueprints/Widgets/HUD/WBP_CharacterHUD.WBP_CharacterHUD_C:Construct",
        function(Context)
            local hud = Context and Context:get() or nil
            if Core.IsValidObj(hud) then
                EnsureHudOverlay(hud)
            end
        end
    )

    Core.TryRegisterHook(
        "ElevatorLabels_Tick",
        "/Script/MainSequence.DMSPlayerController:ReceiveTick",
        function()
            UpdateElevatorPortIcons()
        end
    )
end

function Feature.Init()
    Feature.RegisterHooks()
    Core.Log("[ElevatorLabels] Initialized (UElevatorObject.ItemColumns port icons).")
end

return Feature
