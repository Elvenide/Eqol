-- Eqol Feature: Full Station Map UI Screen
-- Accessible via a "Station" button in WBP_MapHUD_C.
-- Features:
--   - Floor-by-floor 2D top-down view with vertical numbered floor buttons on the right
--   - Renders all station modules and built machines
--   - Item icons on assemblers, refineries, containers, AND conveyor belts (click to toggle in Map & Minimap)
--   - Press B (or click Build) to open WBP_Building_C and place machines directly on the map
--   - Single & multi-machine copy-and-paste (requires materials in inventory)

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "StationMap",
}

local PATHS = {
    WindowBaseClass   = "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C",
    WBPBorderClass    = "/Game/Blueprints/Widgets/Basic/WBP_Border.WBP_Border_C",
    WBPButtonClass    = "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C",
    WBPTextClass      = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass      = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    BuildingMenuClass = "/Game/Blueprints/Widgets/Menus/WBP_Building.WBP_Building_C",
    CanvasPanelClass  = "/Script/UMG.CanvasPanel",
    BorderClass       = "/Script/UMG.Border",
    ButtonClass       = "/Script/UMG.Button",
    SizeBoxClass      = "/Script/UMG.SizeBox",
    OverlayClass      = "/Script/UMG.Overlay",
    VerticalBoxClass  = "/Script/UMG.VerticalBox",
    HorizontalBoxClass= "/Script/UMG.HorizontalBox",
    ScrollBoxClass    = "/Script/UMG.ScrollBox",
    GridPanelClass    = "/Script/UMG.GridPanel",
}

local MAP_CANVAS_W = 980.0
local MAP_CANVAS_H = 680.0

local COLORS = {
    PanelBg       = { R = 0.025, G = 0.038, B = 0.055, A = 0.92 },
    ModuleFill    = { R = 0.080, G = 0.125, B = 0.175, A = 0.95 },
    Assembler     = { R = 0.150, G = 0.620, B = 0.820, A = 0.95 },
    Container     = { R = 0.850, G = 0.600, B = 0.120, A = 0.95 },
    Conveyor      = { R = 0.340, G = 0.420, B = 0.500, A = 0.85 },
    OtherMachine  = { R = 0.250, G = 0.320, B = 0.400, A = 0.88 },
    Selected      = { R = 0.350, G = 0.920, B = 0.550, A = 1.00 },
    PlayerDot     = { R = 0.950, G = 0.950, B = 0.980, A = 1.00 },
    Transparent   = { R = 0.0,   G = 0.0,   B = 0.0,   A = 0.0  },
}

-- UI State
local MapHudInjected = {} -- mapHudAddr -> button
local ActiveMapWin = nil
local MapUI = nil

local CurrentStation = nil
local CurrentFloors = {}
local SelectedFloorIdx = 1
local ViewTransform = { minX = 0, minY = 0, scale = 0.05, offX = 0, offY = 0, floorZ = 0 }

-- Selection, Build & Clipboard State
local SelectedMachines = {} -- addr -> { machine, x, y, z, yaw, buildable, recipe }
local Clipboard = {}        -- { { buildable, dx, dy, yaw, recipe }, ... }
local InteractionMode = "Select" -- "Select" | "BoxSelect" | "Place" | "Paste"
local BoxSelectAnchor = nil
local PendingBuildable = nil
local PendingRotationDeg = 0
local WaitingForBuildMenuSelection = false
local KeyHandlersBound = false
local HookedButtons = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function HookWBPButton(btn, fn)
    if not Core.IsValidObj(btn) then return end
    local addr = btn:GetAddress()
    if HookedButtons[addr] then return end
    HookedButtons[addr] = true

    local inner = btn.Button
    if Core.IsValidObj(inner) then
        pcall(function()
            inner.OnPressed:Add(fn)
        end)
    else
        pcall(function()
            btn.OnPressed:Add(fn)
        end)
    end
end

local function HookRawButton(btn, fn)
    if not Core.IsValidObj(btn) then return end
    local addr = btn:GetAddress()
    if HookedButtons[addr] then return end
    HookedButtons[addr] = true
    pcall(function() btn.OnPressed:Add(fn) end)
end

local function SetCanvasSlot(slot, x, y, w, h, alignX, alignY, zOrder)
    if not Core.IsValidObj(slot) then return end
    pcall(function()
        slot:SetPosition({ X = x, Y = y })
        slot:SetSize({ X = w, Y = h })
        slot:SetAlignment({ X = alignX or 0.5, Y = alignY or 0.5 })
        if zOrder then slot:SetZOrder(zOrder) end
    end)
end

local function WorldToMap(wx, wy)
    local mx = ViewTransform.offX + (wx - ViewTransform.minX) * ViewTransform.scale
    local my = ViewTransform.offY + (wy - ViewTransform.minY) * ViewTransform.scale
    return mx, my
end

local function MapToWorld(mx, my)
    local wx = ViewTransform.minX + (mx - ViewTransform.offX) / ViewTransform.scale
    local wy = ViewTransform.minY + (my - ViewTransform.offY) / ViewTransform.scale
    return wx, wy
end

local function FindPlatformAtWorldXY(wx, wy, floor)
    if not floor then return nil end
    local bestPlat = nil
    local bestDist = math.huge
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        local dx = math.abs(wx - b.cx)
        local dy = math.abs(wy - b.cy)
        if dx <= b.ex and dy <= b.ey then
            return pe.platform
        end
        local d2 = dx * dx + dy * dy
        if d2 < bestDist then
            bestDist = d2
            bestPlat = pe.platform
        end
    end
    return bestPlat
end

local function PlayerHasBuildableMaterials(pc, buildable, count)
    if not Core.IsValidObj(pc) or not Core.IsValidObj(buildable) then return false end
    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return false end

    -- Creative mode bypasses cost naturally in base game
    local okCreative, isCreative = pcall(function() return playerObj.bCreativeMode or pc.bCreativeMode end)
    if okCreative and isCreative then return true end

    local inv = nil
    local okBInv, bInv = pcall(function() return playerObj:GetBuildingInventory() end)
    if okBInv and Core.IsValidObj(bInv) then
        inv = bInv
    elseif Core.IsValidObj(playerObj.Inventory) then
        inv = playerObj.Inventory
    end
    if not Core.IsValidObj(inv) then return true end

    local okCost, costArr = pcall(function() return buildable.ItemCost end)
    if not okCost or not costArr then return true end

    local mult = count or 1
    local hasAll = true
    StationData.ForEachArray(costArr, function(_, elem)
        if not hasAll then return end
        local st = elem
        if type(elem.get) == "function" then
            local okG, g = pcall(function() return elem:get() end)
            if okG then st = g end
        end
        if st and Core.IsValidObj(st.Item) then
            local needed = (tonumber(st.Amount) or 0) * mult
            if needed > 0 then
                local okAmt, have = pcall(function() return inv:GetItemAmount(st.Item) end)
                if okAmt and (tonumber(have) or 0) < needed then
                    hasAll = false
                end
            end
        end
    end)
    return hasAll
end

local function IssueRemoteBuildMachine(pc, frame, buildable, wx, wy, wz, yawDeg, recipe)
    if not (Core.IsValidObj(pc) and Core.IsValidObj(frame) and Core.IsValidObj(buildable)) then
        return false, "Invalid build target"
    end

    if not PlayerHasBuildableMaterials(pc, buildable, 1) then
        return false, "Insufficient materials in inventory"
    end

    -- Snap world coordinates to 100cm grid for clean alignment
    local snapX = math.floor(wx / 100.0 + 0.5) * 100.0
    local snapY = math.floor(wy / 100.0 + 0.5) * 100.0
    local snapZ = wz

    local b = StationData.GetPlatformWorldBounds(frame)
    local relX = snapX - b.cx
    local relY = snapY - b.cy
    local relZ = snapZ - b.cz

    -- Attempt DMSPlayerController:AddBuildMachineCommand using runtime UFunction inspection
    local ufunc = StaticFindObject("/Script/MainSequence.DMSPlayerController:AddBuildMachineCommand")
    local cmdSuccess = false
    if Core.IsValidObj(ufunc) then
        local paramNames = {}
        pcall(function()
            ufunc:ForEachProperty(function(prop)
                local pName = prop:GetFName():ToString()
                table.insert(paramNames, pName)
            end)
        end)

        -- Try common parameter signatures safely via pcall
        local transform = {
            Rotation = { X = 0.0, Y = 0.0, Z = math.sin(math.rad(yawDeg * 0.5)), W = math.cos(math.rad(yawDeg * 0.5)) },
            Translation = { X = relX, Y = relY, Z = relZ },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        local worldTransform = {
            Rotation = transform.Rotation,
            Translation = { X = snapX, Y = snapY, Z = snapZ },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }

        local attempts = {
            function() pc:AddBuildMachineCommand(frame, buildable, transform) end,
            function() pc:AddBuildMachineCommand(buildable, frame, transform) end,
            function() pc:AddBuildMachineCommand(frame, buildable, worldTransform) end,
            function()
                pc:AddBuildMachineCommand({
                    FrameID = frame.ID,
                    Frame = frame,
                    Buildable = buildable,
                    Transform = transform,
                    Location = { X = relX, Y = relY, Z = relZ },
                    Rotation = { Pitch = 0.0, Yaw = yawDeg, Roll = 0.0 },
                })
            end,
        }
        for _, attempt in ipairs(attempts) do
            local ok = pcall(attempt)
            if ok then
                cmdSuccess = true
                break
            end
        end
    end

    if not cmdSuccess then
        return false, "Build command rejected by controller"
    end

    -- If a recipe was copied onto this assembler/refinery, apply it once spawned
    if Core.IsValidObj(recipe) then
        ExecuteInGameThreadWithDelay(200, function()
            local machines = StationData.GetFrameMachines(frame)
            local bestM = nil
            local bestDist = 150.0
            for _, m in ipairs(machines) do
                if StationData.GetMachineCategory(m) == "Assembler" then
                    local mx, my = StationData.GetMachineWorldPosAndYaw(m, b)
                    local d = math.sqrt((mx - snapX) ^ 2 + (my - snapY) ^ 2)
                    if d < bestDist then
                        bestDist = d
                        bestM = m
                    end
                end
            end
            if Core.IsValidObj(bestM) then
                pcall(function() bestM:SetRecipe(recipe) end)
                pcall(function() pc:SetRecipe(bestM, recipe) end)
            end
        end)
    end

    return true, nil
end

--------------------------------------------------------------------------------
-- Map Rendering & Floor Switching
--------------------------------------------------------------------------------

local RefreshStationMapCanvas

local function UpdateStatusBanner(textOverride)
    if not MapUI or not Core.IsValidObj(MapUI.StatusText) then return end
    local msg = textOverride
    if not msg then
        if InteractionMode == "Place" and Core.IsValidObj(PendingBuildable) then
            local bName = "Machine"
            pcall(function() bName = PendingBuildable.DisplayName:ToString() end)
            msg = string.format("BUILD MODE: %s (Rot %d°) — Click module to place | R: Rotate | Esc: Cancel", bName, PendingRotationDeg)
        elseif InteractionMode == "Paste" then
            msg = string.format("PASTE MODE (%d machine(s), Rot %d°) — Click target on floor to paste | R: Rotate | Esc: Cancel", #Clipboard, PendingRotationDeg)
        elseif InteractionMode == "BoxSelect" then
            if BoxSelectAnchor then
                msg = "BOX SELECT: Click opposite corner on map to select machines | Esc: Cancel"
            else
                msg = "BOX SELECT: Click first corner on map | Esc: Cancel"
            end
        else
            local selCount = 0
            for _ in pairs(SelectedMachines) do selCount = selCount + 1 end
            msg = string.format("Floor %d/%d | Selected: %d | B: Build | Click icon: Toggle Map/Minimap visibility",
                SelectedFloorIdx, math.max(1, #CurrentFloors), selCount)
        end
    end
    pcall(function() MapUI.StatusText:SetText(Core.MakeText(msg)) end)
end

local function ClearCanvasChildren(canvas)
    if not Core.IsValidObj(canvas) then return end
    pcall(function() canvas:ClearChildren() end)
end

local function RebuildFloorButtons()
    if not MapUI or not Core.IsValidObj(MapUI.FloorListBox) then return end
    pcall(function() MapUI.FloorListBox:ClearChildren() end)

    local outer = Core.GetWidgetOuter(MapUI.Window)
    -- Render numbered buttons top-to-bottom (highest floor at top, Floor 1 at bottom)
    for i = #CurrentFloors, 1, -1 do
        local flIdx = i
        local btn = Core.CreateUserWidget(PATHS.WBPButtonClass, MapUI.Window, MapUI.PC)
        local lbl = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, MapUI.PC)
        if Core.IsValidObj(btn) and Core.IsValidObj(lbl) then
            pcall(function()
                lbl:SetSize(13)
                lbl:SetText(Core.MakeText(tostring(flIdx)))
                btn:SetContentForSlot(FName("Content"), lbl)
                btn:SetSelected(flIdx == SelectedFloorIdx)
            end)
            HookWBPButton(btn, function()
                SelectedFloorIdx = flIdx
                BoxSelectAnchor = nil
                RebuildFloorButtons()
                RefreshStationMapCanvas()
            end)
            local slot = MapUI.FloorListBox:AddChildToVerticalBox(btn)
            if Core.IsValidObj(slot) then
                pcall(function()
                    slot:SetPadding({ Left = 4.0, Top = 3.0, Right = 4.0, Bottom = 3.0 })
                    slot:SetHorizontalAlignment(0)
                end)
            end
        end
    end
end

local function HandleMapSurfaceClick(mx, my)
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end

    local wx, wy = MapToWorld(mx, my)
    local wz = floor.z

    if InteractionMode == "BoxSelect" then
        if not BoxSelectAnchor then
            BoxSelectAnchor = { wx = wx, wy = wy }
            UpdateStatusBanner()
        else
            local minX = math.min(BoxSelectAnchor.wx, wx)
            local maxX = math.max(BoxSelectAnchor.wx, wx)
            local minY = math.min(BoxSelectAnchor.wy, wy)
            local maxY = math.max(BoxSelectAnchor.wy, wy)
            SelectedMachines = {}
            for _, pe in ipairs(floor.platforms) do
                local machines = StationData.GetFrameMachines(pe.platform)
                for _, m in ipairs(machines) do
                    local mwx, mwy, mwz, myaw = StationData.GetMachineWorldPosAndYaw(m, pe.bounds)
                    if mwx >= minX and mwx <= maxX and mwy >= minY and mwy <= maxY then
                        local okB, bld = pcall(function() return m.Buildable end)
                        local okR, rec = pcall(function() return m.Recipe end)
                        SelectedMachines[m:GetAddress()] = {
                            machine = m,
                            x = mwx,
                            y = mwy,
                            z = mwz,
                            yaw = myaw,
                            buildable = okB and bld or nil,
                            recipe = okR and rec or nil,
                        }
                    end
                end
            end
            BoxSelectAnchor = nil
            InteractionMode = "Select"
            RefreshStationMapCanvas()
        end
        return
    end

    if InteractionMode == "Place" and Core.IsValidObj(PendingBuildable) then
        local pc = Core.GetLocalPlayerController()
        local targetPlat = FindPlatformAtWorldXY(wx, wy, floor)
        local ok, err = IssueRemoteBuildMachine(pc, targetPlat, PendingBuildable, wx, wy, wz, PendingRotationDeg, nil)
        if not ok and err then
            UpdateStatusBanner("Build failed: " .. err)
        else
            ExecuteInGameThreadWithDelay(150, RefreshStationMapCanvas)
        end
        return
    end

    if InteractionMode == "Paste" and #Clipboard > 0 then
        local pc = Core.GetLocalPlayerController()
        local rad = math.rad(PendingRotationDeg)
        local cosA = math.cos(rad)
        local sinA = math.sin(rad)
        local placedAny = false
        local lastErr = nil

        for _, item in ipairs(Clipboard) do
            if Core.IsValidObj(item.buildable) then
                local rdx = item.dx * cosA - item.dy * sinA
                local rdy = item.dx * sinA + item.dy * cosA
                local tx = wx + rdx
                local ty = wy + rdy
                local targetPlat = FindPlatformAtWorldXY(tx, ty, floor)
                local ok, err = IssueRemoteBuildMachine(pc, targetPlat, item.buildable, tx, ty, wz, (item.yaw or 0) + PendingRotationDeg, item.recipe)
                if ok then
                    placedAny = true
                else
                    lastErr = err
                end
            end
        end

        if lastErr and not placedAny then
            UpdateStatusBanner("Paste failed: " .. lastErr)
        else
            ExecuteInGameThreadWithDelay(200, RefreshStationMapCanvas)
        end
        return
    end
end

RefreshStationMapCanvas = function()
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return end

    ClearCanvasChildren(MapUI.MapCanvas)

    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor or #floor.platforms == 0 then
        UpdateStatusBanner("No station modules on this floor")
        return
    end

    -- Compute floor bounding box in Unreal world coordinates
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        if b.cx - b.ex < minX then minX = b.cx - b.ex end
        if b.cx + b.ex > maxX then maxX = b.cx + b.ex end
        if b.cy - b.ey < minY then minY = b.cy - b.ey end
        if b.cy + b.ey > maxY then maxY = b.cy + b.ey end
    end

    local pad = 40.0
    local spanX = math.max(1200.0, maxX - minX)
    local spanY = math.max(1200.0, maxY - minY)
    local scale = math.min((MAP_CANVAS_W - pad * 2.0) / spanX, (MAP_CANVAS_H - pad * 2.0) / spanY)

    ViewTransform.minX = minX
    ViewTransform.minY = minY
    ViewTransform.scale = scale
    ViewTransform.offX = (MAP_CANVAS_W - spanX * scale) * 0.5
    ViewTransform.offY = (MAP_CANVAS_H - spanY * scale) * 0.5
    ViewTransform.floorZ = floor.z

    local outer = Core.GetWidgetOuter(MapUI.Window)

    -- 1. Render clickable module surfaces
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        local mx, my = WorldToMap(b.cx, b.cy)
        local mw = math.max(24.0, b.ex * 2.0 * scale - 2.0)
        local mh = math.max(24.0, b.ey * 2.0 * scale - 2.0)

        local modBtn = Core.CreateRawWidget(PATHS.ButtonClass, outer)
        local modBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if Core.IsValidObj(modBtn) and Core.IsValidObj(modBorder) then
            pcall(function()
                modBtn:SetBackgroundColor(COLORS.Transparent)
                modBorder:SetBrushColor(COLORS.ModuleFill)
            end)
            modBtn:AddChild(modBorder)
            local slot = MapUI.MapCanvas:AddChildToCanvas(modBtn)
            SetCanvasSlot(slot, mx, my, mw, mh, 0.5, 0.5, 1)

            local platCx, platCy = b.cx, b.cy
            local platMx, platMy = mx, my
            HookRawButton(modBtn, function()
                if InteractionMode == "Select" then
                    SelectedMachines = {}
                    RefreshStationMapCanvas()
                else
                    HandleMapSurfaceClick(platMx, platMy)
                end
            end)
        end
    end

    -- 2. Render all machines + item icons (including conveyors!)
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        local machines = StationData.GetFrameMachines(pe.platform)
        for _, m in ipairs(machines) do
            local mwx, mwy, mwz, myaw = StationData.GetMachineWorldPosAndYaw(m, b)
            local mx, my = WorldToMap(mwx, mwy)
            local cat = StationData.GetMachineCategory(m)
            local mAddr = m:GetAddress()
            local isSel = SelectedMachines[mAddr] ~= nil

            local col = COLORS.OtherMachine
            local baseSize = 18.0
            if cat == "Assembler" then
                col = COLORS.Assembler
                baseSize = 26.0
            elseif cat == "Container" then
                col = COLORS.Container
                baseSize = 22.0
            elseif cat == "Conveyor" then
                col = COLORS.Conveyor
                baseSize = 12.0
            end
            if isSel then
                col = COLORS.Selected
            end

            local machBtn = Core.CreateRawWidget(PATHS.ButtonClass, outer)
            local machBox = Core.CreateRawWidget(PATHS.BorderClass, outer)
            if Core.IsValidObj(machBtn) and Core.IsValidObj(machBox) then
                pcall(function()
                    machBtn:SetBackgroundColor(COLORS.Transparent)
                    machBox:SetBrushColor(col)
                end)
                machBtn:AddChild(machBox)
                local mSlot = MapUI.MapCanvas:AddChildToCanvas(machBtn)
                SetCanvasSlot(mSlot, mx, my, baseSize, baseSize, 0.5, 0.5, isSel and 20 or 10)

                HookRawButton(machBtn, function()
                    if InteractionMode == "BoxSelect" or InteractionMode == "Place" or InteractionMode == "Paste" then
                        HandleMapSurfaceClick(mx, my)
                        return
                    end
                    local pc = Core.GetLocalPlayerController()
                    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
                    local isShift = false
                    if Core.IsValidObj(pc) then
                        pcall(function() isShift = pc:IsInputKeyDown({ KeyName = FName("LeftShift") }) or pc:IsInputKeyDown({ KeyName = FName("RightShift") }) end)
                    end
                    if not isShift then
                        SelectedMachines = {}
                    end
                    if SelectedMachines[mAddr] then
                        SelectedMachines[mAddr] = nil
                    else
                        local okB, bld = pcall(function() return m.Buildable end)
                        local okR, rec = pcall(function() return m.Recipe end)
                        SelectedMachines[mAddr] = {
                            machine = m,
                            x = mwx,
                            y = mwy,
                            z = mwz,
                            yaw = myaw,
                            buildable = okB and bld or nil,
                            recipe = okR and rec or nil,
                        }
                    end
                    RefreshStationMapCanvas()
                end)
            end

            -- Item icon overlay for Assembler, Refinery, Container, AND Conveyor Belt
            if cat == "Assembler" or cat == "Container" or cat == "Conveyor" then
                local item = StationData.GetPrimaryItemForMachine(m)
                if Core.IsValidObj(item) then
                    local isHidden = StationData.IsMachineIconHidden(m)
                    local iconBtn = Core.CreateRawWidget(PATHS.ButtonClass, outer)
                    local iconWidget = Core.CreateUserWidget(PATHS.WBPItemClass, MapUI.Window, MapUI.PC)
                    if Core.IsValidObj(iconBtn) and Core.IsValidObj(iconWidget) then
                        pcall(function()
                            iconBtn:SetBackgroundColor(COLORS.Transparent)
                            iconBtn:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = isHidden and 0.25 or 1.0 })
                            iconWidget:SetIconSize(cat == "Conveyor" and 14.0 or 18.0)
                            iconWidget:SetItem(item)
                        end)
                        iconBtn:AddChild(iconWidget)
                        local iSlot = MapUI.MapCanvas:AddChildToCanvas(iconBtn)
                        SetCanvasSlot(iSlot, mx, my, 22.0, 22.0, 0.5, 0.5, 30)

                        HookRawButton(iconBtn, function()
                            StationData.ToggleMachineIcon(m)
                            RefreshStationMapCanvas()
                        end)
                    end
                end
            end
        end
    end

    -- 3. Render Player marker if player is on this floor
    local pc = Core.GetLocalPlayerController()
    local pawn = Core.IsValidObj(pc) and pc.Pawn or nil
    if Core.IsValidObj(pawn) then
        local okLoc, loc = pcall(function() return pawn:K2_GetActorLocation() end)
        if okLoc and loc and math.abs((loc.Z or 0) - floor.z) <= 250.0 then
            local pmx, pmy = WorldToMap(loc.X or 0, loc.Y or 0)
            local pDot = Core.CreateRawWidget(PATHS.BorderClass, outer)
            if Core.IsValidObj(pDot) then
                pcall(function() pDot:SetBrushColor(COLORS.PlayerDot) end)
                local pSlot = MapUI.MapCanvas:AddChildToCanvas(pDot)
                SetCanvasSlot(pSlot, pmx, pmy, 10.0, 10.0, 0.5, 0.5, 45)
            end
        end
    end

    UpdateStatusBanner()
end

--------------------------------------------------------------------------------
-- Window Open / Close & Toolbar Actions
--------------------------------------------------------------------------------

local function CloseStationMap()
    InteractionMode = "Select"
    PendingBuildable = nil
    BoxSelectAnchor = nil
    WaitingForBuildMenuSelection = false
    if Core.IsValidObj(ActiveMapWin) then
        pcall(function() ActiveMapWin:RemoveFromParent() end)
    end
    ActiveMapWin = nil
    MapUI = nil
end

local function CopySelectedMachines()
    Clipboard = {}
    local list = {}
    for _, entry in pairs(SelectedMachines) do
        if Core.IsValidObj(entry.machine) and Core.IsValidObj(entry.buildable) then
            table.insert(list, entry)
        end
    end
    if #list == 0 then
        UpdateStatusBanner("Select one or more machines first before copying")
        return
    end

    local cx, cy = 0, 0
    for _, e in ipairs(list) do
        cx = cx + e.x
        cy = cy + e.y
    end
    cx = cx / #list
    cy = cy / #list

    for _, e in ipairs(list) do
        table.insert(Clipboard, {
            buildable = e.buildable,
            dx = e.x - cx,
            dy = e.y - cy,
            yaw = e.yaw or 0,
            recipe = e.recipe,
        })
    end

    InteractionMode = "Paste"
    PendingRotationDeg = 0
    UpdateStatusBanner()
end

local function OpenBuildMenuFromStationMap()
    local pc = Core.GetLocalPlayerController()
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    local bldCls = Core.FindOrLoadClass(PATHS.BuildingMenuClass)
    if not (Core.IsValidObj(pc) and Core.IsValidObj(widgetSub) and Core.IsValidObj(bldCls)) then
        return
    end

    WaitingForBuildMenuSelection = true
    pcall(function()
        widgetSub:ShowWindow(bldCls, nil, nil)
    end)
end

local function OpenStationMap()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
    if not inStation or not Core.IsValidObj(walkFrame) then
        -- Fallback: check DMSWorld.Stations[1] if player opened Map while docked/nearby
        local worldSub = Core.GetWorldSubsystem(pc, Core.PATHS.WorldSubsystemClass)
        if Core.IsValidObj(worldSub) then
            local okW, dmsWorld = pcall(function() return worldSub:GetDMSWorld() end)
            if okW and Core.IsValidObj(dmsWorld) and dmsWorld.Stations then
                StationData.ForEachArray(dmsWorld.Stations, function(_, elem)
                    if not Core.IsValidObj(station) then
                        station = Core.UnwrapArrayElem(elem)
                    end
                end)
            end
        end
    end

    if not Core.IsValidObj(station) and not Core.IsValidObj(walkFrame) then
        Core.Log("StationMap: no station found for player")
        return
    end

    if Core.IsValidObj(ActiveMapWin) then
        CloseStationMap()
    end

    local win = Core.CreateUserWidget(PATHS.WindowBaseClass, pc, pc)
    if not Core.IsValidObj(win) then
        Core.Log("StationMap: failed to construct WBP_WindowBase_C")
        return
    end

    ActiveMapWin = win
    local outer = Core.GetWidgetOuter(win)

    pcall(function()
        win:SetWindowName(Core.MakeText("Station Map"))
        win:AddToViewport(50)
    end)

    -- Root layout inside WBP_WindowBase.Content
    local rootVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local toolbarHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local bodyHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local mapBg = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local mapCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local floorScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local floorListBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local statusText = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)

    if not (Core.IsValidObj(rootVBox) and Core.IsValidObj(toolbarHBox) and Core.IsValidObj(bodyHBox)
        and Core.IsValidObj(mapBg) and Core.IsValidObj(mapCanvas) and Core.IsValidObj(floorListBox)) then
        return
    end

    pcall(function()
        mapBg:SetBrushColor(COLORS.PanelBg)
        mapCanvas:SetClipping(1)
        win:SetContentForSlot(FName("Content"), rootVBox)
    end)

    -- Toolbar buttons matching WBP_Button style
    local function AddToolButton(labelStr, onClick)
        local btn = Core.CreateUserWidget(PATHS.WBPButtonClass, win, pc)
        local txt = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
        if Core.IsValidObj(btn) and Core.IsValidObj(txt) then
            pcall(function()
                txt:SetSize(12)
                txt:SetText(Core.MakeText(labelStr))
                btn:SetContentForSlot(FName("Content"), txt)
            end)
            HookWBPButton(btn, onClick)
            local sl = toolbarHBox:AddChildToHorizontalBox(btn)
            if Core.IsValidObj(sl) then
                pcall(function() sl:SetPadding({ Left = 0.0, Top = 0.0, Right = 8.0, Bottom = 0.0 }) end)
            end
        end
    end

    AddToolButton("Build (B)", OpenBuildMenuFromStationMap)
    AddToolButton("Box Select", function()
        InteractionMode = (InteractionMode == "BoxSelect") and "Select" or "BoxSelect"
        BoxSelectAnchor = nil
        UpdateStatusBanner()
    end)
    AddToolButton("Copy", CopySelectedMachines)
    AddToolButton("Paste", function()
        if #Clipboard > 0 then
            InteractionMode = "Paste"
            PendingRotationDeg = 0
            UpdateStatusBanner()
        else
            UpdateStatusBanner("Clipboard is empty")
        end
    end)
    AddToolButton("Rotate (R)", function()
        PendingRotationDeg = (PendingRotationDeg + 90) % 360
        UpdateStatusBanner()
    end)
    AddToolButton("Close", CloseStationMap)

    if Core.IsValidObj(statusText) then
        pcall(function() statusText:SetSize(12) end)
        local stSlot = toolbarHBox:AddChildToHorizontalBox(statusText)
        if Core.IsValidObj(stSlot) then
            pcall(function()
                stSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                stSlot:SetVerticalAlignment(2)
                stSlot:SetPadding({ Left = 12.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
    end

    local tbSlot = rootVBox:AddChildToVerticalBox(toolbarHBox)
    if Core.IsValidObj(tbSlot) then
        pcall(function() tbSlot:SetPadding({ Left = 8.0, Top = 6.0, Right = 8.0, Bottom = 6.0 }) end)
    end

    -- Body: Map Canvas (left) + Floor Selector (right)
    local mapSizeBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    pcall(function()
        mapSizeBox:SetWidthOverride(MAP_CANVAS_W)
        mapSizeBox:SetHeightOverride(MAP_CANVAS_H)
    end)
    mapBg:AddChild(mapCanvas)
    mapSizeBox:AddChild(mapBg)

    local mapBodySlot = bodyHBox:AddChildToHorizontalBox(mapSizeBox)
    if Core.IsValidObj(mapBodySlot) then
        pcall(function() mapBodySlot:SetSize({ Value = 1.0, SizeRule = 1 }) end)
    end

    local floorPanelBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    pcall(function() floorPanelBox:SetWidthOverride(56.0) end)
    if Core.IsValidObj(floorScroll) then
        floorScroll:AddChild(floorListBox)
        floorPanelBox:AddChild(floorScroll)
    else
        floorPanelBox:AddChild(floorListBox)
    end

    local floorBodySlot = bodyHBox:AddChildToHorizontalBox(floorPanelBox)
    if Core.IsValidObj(floorBodySlot) then
        pcall(function()
            floorBodySlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            floorBodySlot:SetVerticalAlignment(0)
        end)
    end

    rootVBox:AddChildToVerticalBox(bodyHBox)

    -- Hook CloseWindow on WBP_WindowHeader if present
    if Core.IsValidObj(win.WBP_WindowHeader) and Core.IsValidObj(win.WBP_WindowHeader.CloseButton) then
        HookWBPButton(win.WBP_WindowHeader.CloseButton, CloseStationMap)
    end

    MapUI = {
        Window = win,
        PC = pc,
        MapCanvas = mapCanvas,
        FloorListBox = floorListBox,
        StatusText = statusText,
    }

    -- Resolve floors & render
    local pz = 0
    if Core.IsValidObj(pc.Pawn) then
        local okLoc, loc = pcall(function() return pc.Pawn:K2_GetActorLocation() end)
        if okLoc and loc then pz = loc.Z or 0 end
    end

    CurrentStation = station
    CurrentFloors, SelectedFloorIdx = StationData.BuildStationFloorMap(station, walkFrame, pz)
    SelectedMachines = {}
    InteractionMode = "Select"
    BoxSelectAnchor = nil

    RebuildFloorButtons()
    RefreshStationMapCanvas()
end

--------------------------------------------------------------------------------
-- WBP_MapHUD_C "Station" Button Injection
--------------------------------------------------------------------------------

local function EnsureStationButtonOnMapHud(mapHud)
    if not Core.IsValidObj(mapHud) then return end
    local addr = mapHud:GetAddress()
    if Core.IsValidObj(MapHudInjected[addr]) then return end

    local container = mapHud.ViewSelectContainer
    if not Core.IsValidObj(container) then return end

    local okPC, owningPC = pcall(function() return mapHud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local btn = Core.CreateUserWidget(PATHS.WBPButtonClass, mapHud, pc)
    local lbl = Core.CreateUserWidget(PATHS.WBPTextClass, mapHud, pc)
    if not (Core.IsValidObj(btn) and Core.IsValidObj(lbl)) then return end

    pcall(function()
        lbl:SetSize(13)
        lbl:SetText(Core.MakeText("Station"))
        btn:SetContentForSlot(FName("Content"), lbl)
    end)

    HookWBPButton(btn, OpenStationMap)

    local colIdx = 3
    pcall(function()
        local children = container:GetAllChildren()
        if children then
            local count = 0
            StationData.ForEachArray(children, function() count = count + 1 end)
            colIdx = count
        end
    end)

    local slot = container:AddChildToGrid(btn, 0, colIdx)
    if Core.IsValidObj(slot) and Core.IsValidObj(mapHud.SystemButton) and Core.IsValidObj(mapHud.SystemButton.Slot) then
        pcall(function()
            slot:SetPadding(mapHud.SystemButton.Slot.Padding)
        end)
    end

    MapHudInjected[addr] = btn
    Core.Log("Injected Station Map button into WBP_MapHUD_C")
end

--------------------------------------------------------------------------------
-- Keybinds inside Station Map (B = Build, R = Rotate, Esc = Cancel/Close)
--------------------------------------------------------------------------------

local function EnsureMapKeybinds()
    if KeyHandlersBound or not Key then return end
    KeyHandlersBound = true

    if Key.B then
        RegisterKeyBind(Key.B, function()
            if Core.IsValidObj(ActiveMapWin) and not WaitingForBuildMenuSelection then
                ExecuteInGameThread(OpenBuildMenuFromStationMap)
            end
        end)
    end

    if Key.R then
        RegisterKeyBind(Key.R, function()
            if Core.IsValidObj(ActiveMapWin) and (InteractionMode == "Place" or InteractionMode == "Paste") then
                ExecuteInGameThread(function()
                    PendingRotationDeg = (PendingRotationDeg + 90) % 360
                    UpdateStatusBanner()
                end)
            end
        end)
    end

    if Key.ESCAPE then
        RegisterKeyBind(Key.ESCAPE, function()
            if Core.IsValidObj(ActiveMapWin) and not WaitingForBuildMenuSelection then
                ExecuteInGameThread(function()
                    if InteractionMode ~= "Select" then
                        InteractionMode = "Select"
                        PendingBuildable = nil
                        BoxSelectAnchor = nil
                        UpdateStatusBanner()
                    else
                        CloseStationMap()
                    end
                end)
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_MapHUD_C = function(mapHud)
        EnsureStationButtonOnMapHud(mapHud)
    end,
}

function Feature.Init()
    EnsureMapKeybinds()
    StationData.OnIconVisibilityChanged(function()
        if Core.IsValidObj(ActiveMapWin) then
            pcall(RefreshStationMapCanvas)
        end
    end)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "MapHUD_OnMapOpened",
        "/Game/Blueprints/Widgets/HUDs/Map/WBP_MapHUD.WBP_MapHUD_C:OnMapOpened",
        function(Context)
            local mapHud = Context:get()
            if Core.IsValidObj(mapHud) then
                EnsureStationButtonOnMapHud(mapHud)
            end
        end
    )

    Core.TryRegisterHook(
        "Building_BuildableSelected_StationMap",
        "/Game/Blueprints/Widgets/Menus/WBP_Building.WBP_Building_C:BuildableSelected",
        function(Context, BuildableParam)
            if not WaitingForBuildMenuSelection or not Core.IsValidObj(ActiveMapWin) then
                return
            end
            WaitingForBuildMenuSelection = false
            local bld = Core.UnwrapArrayElem(BuildableParam)
            if Core.IsValidObj(bld) then
                PendingBuildable = bld
                InteractionMode = "Place"
                PendingRotationDeg = 0
                local pc = Core.GetLocalPlayerController()
                if Core.IsValidObj(pc) then
                    pcall(function() pc:ExitBuildingMode() end)
                end
                UpdateStatusBanner()
            end
        end
    )

    -- Inject into any already-constructed WBP_MapHUD_C
    local ok, list = pcall(FindAllOf, "WBP_MapHUD_C")
    if ok and list then
        for _, m in ipairs(list) do
            if Core.IsValidObj(m) then EnsureStationButtonOnMapHud(m) end
        end
    end
end

function Feature.PruneCaches()
    for addr, btn in pairs(MapHudInjected) do
        if not Core.IsValidObj(btn) then
            MapHudInjected[addr] = nil
        end
    end
    if ActiveMapWin and not Core.IsValidObj(ActiveMapWin) then
        ActiveMapWin = nil
        MapUI = nil
    end
end

return Feature
