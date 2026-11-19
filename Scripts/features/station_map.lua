-- Eqol Feature: Interactive Gridded Station Map
-- Accessible via configurable keybind (default N).
-- Features:
--   - Gridded 2D top-down view (1 cell = 1x1 machine / 100cm conveyor belt)
--   - Station floors matching total elevator stack height, with tall vertical paginated floor selector (^ / 5..1 / v)
--   - Tier-shaded type-colored machine rectangles with 2D build-menu asset icons
--   - Containers display contained items; Producers display output items & rates/min (clickable toggles)
--   - Hover tooltip showing conveyor belt carried items on mouse hover
--   - Hold-click box select, Shift+Click multi-select, Ctrl+C / Copy -> repeatable multi-ghost Paste (right-click cancels)
--   - Press B to pick a machine and place cursor ghost(s) directly on the map, with bottom-right Apply Changes button

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "StationMap",
}

local PATHS = {
    WindowBaseClass   = "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C",
    WBPButtonClass    = "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C",
    WBPTextClass      = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass      = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    BuildingMenuClass = "/Game/Blueprints/Widgets/Menus/WBP_Building.WBP_Building_C",
    CanvasPanelClass  = "/Script/UMG.CanvasPanel",
    ImageClass        = "/Script/UMG.Image",
    BorderClass       = "/Script/UMG.Border",
    SizeBoxClass      = "/Script/UMG.SizeBox",
    OverlayClass      = "/Script/UMG.Overlay",
    ScrollBoxClass    = "/Script/UMG.ScrollBox",
    SpacerClass       = "/Script/UMG.Spacer",
    VerticalBoxClass  = "/Script/UMG.VerticalBox",
    HorizontalBoxClass= "/Script/UMG.HorizontalBox",
    WidgetLayoutLibCDO= "/Script/UMG.Default__WidgetLayoutLibrary",
    SlateLibCDO       = "/Script/UMG.Default__SlateBlueprintLibrary",
}

local CELL_CM = 100.0
local BASE_CELL_PX = 48.0
local BASE_PX_PER_CM = BASE_CELL_PX / CELL_CM
local FLOOR_PAGE_SIZE = 7
local DEFAULT_CANVAS_W = 1060.0
local DEFAULT_CANVAS_H = 740.0

local COLORS = {
    WindowBg      = { R = 0.024, G = 0.032, B = 0.044, A = 0.96 },
    GridLine      = { R = 0.240, G = 0.300, B = 0.380, A = 0.28 },
    GridMajor     = { R = 0.340, G = 0.430, B = 0.540, A = 0.48 },
    ModuleFill    = { R = 0.085, G = 0.115, B = 0.155, A = 0.92 },
    ModuleBorder  = { R = 0.720, G = 0.800, B = 0.900, A = 0.96 },
    Assembler     = { R = 0.150, G = 0.560, B = 0.760, A = 0.92 },
    Container     = { R = 0.780, G = 0.560, B = 0.140, A = 0.92 },
    Conveyor      = { R = 0.290, G = 0.360, B = 0.440, A = 0.90 },
    OtherMachine  = { R = 0.240, G = 0.300, B = 0.380, A = 0.90 },
    DirChevron    = { R = 0.920, G = 0.850, B = 0.450, A = 0.85 },
    Selected      = { R = 0.980, G = 0.650, B = 0.100, A = 0.95 },
    SelectedFill  = { R = 0.980, G = 0.650, B = 0.100, A = 0.22 },
    BoxSelectLine = { R = 0.350, G = 0.920, B = 0.550, A = 0.95 },
    BoxSelectFill = { R = 0.350, G = 0.920, B = 0.550, A = 0.18 },
    GhostValid    = { R = 0.450, G = 0.900, B = 1.000, A = 0.58 },
    GhostInvalid  = { R = 1.000, G = 0.320, B = 0.320, A = 0.58 },
    GhostBorderOk = { R = 0.350, G = 0.920, B = 0.650, A = 0.90 },
    GhostBorderBad= { R = 1.000, G = 0.300, B = 0.300, A = 0.90 },
    WallFill      = { R = 0.030, G = 0.040, B = 0.056, A = 1.00 },
    WallBorder    = { R = 0.860, G = 0.910, B = 0.970, A = 0.92 },
    FloorRailBg   = { R = 0.045, G = 0.060, B = 0.082, A = 0.95 },
    FloorSelected = { R = 0.940, G = 0.620, B = 0.080, A = 1.00 },
    FloorNormal   = { R = 0.120, G = 0.155, B = 0.205, A = 0.90 },
    TooltipBg     = { R = 0.035, G = 0.048, B = 0.068, A = 0.96 },
    TooltipBorder = { R = 0.480, G = 0.640, B = 0.820, A = 0.95 },
    PlayerLocal   = { R = 0.960, G = 0.970, B = 1.000, A = 1.00 },
    PlayerOnline  = { R = 0.250, G = 0.880, B = 0.380, A = 1.00 },
    PlayerOffline = { R = 0.650, G = 0.280, B = 0.280, A = 0.92 },
    Transparent   = { R = 0.0,   G = 0.0,   B = 0.0,   A = 0.0  },
}

-- UI & Map State
local MapHudInjected = {}
local ActiveMapWin = nil
local MapWinVisible = false
local MapWinInViewport = false
local MapUI = nil
local CachedBorderCls = nil
local CanvasRenderGen = 0
local BuildGridDivisor = 50.0
local BuildHeightDivisor = 50.0
local GridCalibrated = false
local PrewarmScheduledForWorld = nil

local ALIGN_CENTER = { X = 0.5, Y = 0.5 }
local function AddBorderFast(outer, canvas, x, y, w, h, col, zOrder)
    if not Core.IsValidObj(CachedBorderCls) then
        CachedBorderCls = Core.FindOrLoadClass(PATHS.BorderClass)
    end
    if not Core.IsValidObj(CachedBorderCls) or not Core.IsValidObj(outer) then return nil, nil end
    local ok, b = pcall(StaticConstructObject, CachedBorderCls, outer)
    if not ok or not Core.IsValidObj(b) then return nil, nil end
    b:SetVisibility(3)
    b:SetBrushColor(col)
    local s = canvas:AddChildToCanvas(b)
    if Core.IsValidObj(s) then
        s:SetPosition({ X = x, Y = y })
        s:SetSize({ X = w, Y = h })
        s:SetAlignment(ALIGN_CENTER)
        if zOrder then s:SetZOrder(zOrder) end
    end
    return b, s
end

local function IsMapOpen()
    return MapWinVisible and Core.IsValidObj(ActiveMapWin)
end

local CurrentStation = nil
local CurrentWalkFrame = nil
local CurrentFrameXform = nil
local CurrentFloors = {}
local SelectedFloorIdx = 1
local FloorPageTopIdx = nil -- highest floor index currently shown in the 5-slot floor bar

local ViewTransform = {
    cx = 0.0,
    cy = 0.0,
    scale = 0.24,
    canvasW = DEFAULT_CANVAS_W,
    canvasH = DEFAULT_CANVAS_H,
    gridOriginX = 0.0,
    gridOriginY = 0.0,
    floorZ = 0.0,
    hasFitted = false,
}

-- Rendered Floor Cache (for fast hit-testing, box select, and hover without rebuilding widgets)
local RenderedMachines = {}  -- list of { machine, x, y, z, yaw, cellsX, cellsY, halfW, halfH, cat, buildable, recipe, actorClsPath, displayName }
local RenderedConveyors = {} -- subset of RenderedMachines where cat == "Conveyor"
local RenderedPorts = {}     -- unconnected item ports: { idx, x, y, halfW, halfH, isInput, isOutput, machineName }
local RenderedGridLines = {} -- { border, slot, isVertical, spanOther, isMajor4, isMajor8 }
local LastGridTier = nil
local LastGridZoomRatio = nil
local FloorIconButtons = {}  -- mAddr -> { btn, widget }
local FloorRailButtons = {}  -- list of WBP_Button_C instances in floor selector
local TrackedButtons = {}    -- list of static WBP_Button_C instances for hover check
local IconDiagLogged = false
local MissingIconsLogged = {}
local CursorDiagLogged = false
local LastHoveredConvAddr = nil
local LastHoveredPortIdx = nil
local LastHadDynamicOverlay = false

-- Selection, Ghosts, Build & Clipboard State
local SelectedMachines = {}  -- mAddr -> entry
local Clipboard = {}         -- { { buildable, dx, dy, yaw, recipe, cellsX, cellsY, actorClsPath, name }, ... }
local PendingGhosts = {}     -- { { buildable, x, y, z, yaw, cellsX, cellsY, actorClsPath, recipe, name }, ... }
local InteractionMode = "Select" -- "Select" | "Place" | "Paste"
local PendingBuildable = nil
local PendingRotationDeg = 0
local WaitingForBuildMenuSelection = false
local WaitingBuildMenuSince = 0
local KeyHandlersBound = false
local LastWorldAddr = nil
local SavedCharInputEnabled = nil

-- Input Polling State
local InputPollActive = false
local MouseState = {
    wasLDown = false,
    wasRDown = false,
    lDownInMap = false,
    lDraggingBox = false,
    lStartX = 0, lStartY = 0,
    rDownInMap = false,
    rPanning = false,
    rStartX = 0, rStartY = 0,
    panStartCx = 0, panStartCy = 0,
    lastCursorMx = nil, lastCursorMy = nil,
}

-- Cached 2D Visual Styles per machine class (cached across opens in same world)
local MachineSpriteCache = {} -- clsKey -> { tex, bgCol, borderCol, typeKey, tier, directional }

-- Forward declarations
local RefreshStationMapCanvas
local RebuildFloorButtons
local RefreshDynamicOverlay
local UpdateActionBar
local UpdateStatusBanner
local CloseStationMap

--------------------------------------------------------------------------------
-- Geometry, Transform & Helpers
--------------------------------------------------------------------------------

local function GetCurrentWorldAddr()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return nil end
    local okW, w = pcall(function() return pc:GetWorld() end)
    if okW and Core.IsValidObj(w) then
        return w:GetAddress()
    end
    return nil
end

local function SafeFNameStr(obj)
    if not Core.IsValidObj(obj) then return nil end
    local ok, s = pcall(function() return obj:GetFName():ToString() end)
    if ok and type(s) == "string" and s ~= "" then return s end
    return nil
end

local function SafeFullPath(obj)
    if not Core.IsValidObj(obj) then return nil end
    local ok, full = pcall(function() return obj:GetFullName() end)
    if ok and type(full) == "string" and full ~= "" then
        return full:match("^%S+ (.+)$") or full
    end
    return nil
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

local function WorldToCanvas(wx, wy)
    local mx = ViewTransform.canvasW * 0.5 + (wx - ViewTransform.cx) * ViewTransform.scale
    local my = ViewTransform.canvasH * 0.5 + (wy - ViewTransform.cy) * ViewTransform.scale
    return mx, my
end

local function WorldToBaseCanvas(wx, wy)
    return wx * BASE_PX_PER_CM, wy * BASE_PX_PER_CM
end

local function UpdateGridAppearanceForZoom(zoomRatio)
    if #RenderedGridLines == 0 or not zoomRatio or zoomRatio <= 0.001 then return end
    local screenCellPx = CELL_CM * ViewTransform.scale
    local tier = (screenCellPx >= 10.0) and 1 or ((screenCellPx >= 3.8) and 2 or 3)
    local tierChanged = (tier ~= LastGridTier)
    local ratioChanged = (not LastGridZoomRatio) or (math.abs(zoomRatio - LastGridZoomRatio) / math.max(0.01, LastGridZoomRatio) > 0.08)
    if not tierChanged and not ratioChanged then return end

    LastGridTier = tier
    LastGridZoomRatio = zoomRatio

    local minorThick = math.max(1.05, 1.1) / zoomRatio
    local majorThick = math.max(1.55, 1.7) / zoomRatio

    for _, gl in ipairs(RenderedGridLines) do
        local show
        if tier == 1 then
            show = true
        elseif tier == 2 then
            show = gl.isMajor4
        else
            show = gl.isMajor8
        end
        if Core.IsValidObj(gl.border) then
            if tierChanged then
                pcall(function() gl.border:SetVisibility(show and 3 or 1) end)
            end
            if show and Core.IsValidObj(gl.slot) then
                local isEmph = (tier == 1 and gl.isMajor4) or (tier >= 2 and gl.isMajor8)
                local thick = isEmph and majorThick or minorThick
                pcall(function()
                    if gl.isVertical then
                        gl.slot:SetSize({ X = thick, Y = gl.spanOther })
                    else
                        gl.slot:SetSize({ X = gl.spanOther, Y = thick })
                    end
                end)
            end
        end
    end
end

local function ApplyViewTransform()
    if not MapUI then return end
    local zoomRatio = ViewTransform.scale / BASE_PX_PER_CM
    local tx = ViewTransform.canvasW * 0.5 - ViewTransform.cx * ViewTransform.scale
    local ty = ViewTransform.canvasH * 0.5 - ViewTransform.cy * ViewTransform.scale
    local pivot = { X = 0.0, Y = 0.0 }
    local sc = { X = zoomRatio, Y = zoomRatio }
    local tr = { X = tx, Y = ty }
    for _, p in ipairs({ MapUI.BgPanZoom, MapUI.IconPanZoom }) do
        if Core.IsValidObj(p) then
            pcall(function()
                p:SetRenderTransformPivot(pivot)
                p:SetRenderScale(sc)
                p:SetRenderTranslation(tr)
            end)
        end
    end
    UpdateGridAppearanceForZoom(zoomRatio)
end

local function CanvasToWorld(mx, my)
    local wx = ViewTransform.cx + (mx - ViewTransform.canvasW * 0.5) / ViewTransform.scale
    local wy = ViewTransform.cy + (my - ViewTransform.canvasH * 0.5) / ViewTransform.scale
    return wx, wy
end

local function GetRotatedCellDims(cellsX, cellsY, yawDeg)
    local norm = (math.floor((yawDeg or 0) / 90.0 + 0.5) % 4 + 4) % 4
    if norm == 1 or norm == 3 then
        return cellsY, cellsX
    end
    return cellsX, cellsY
end

local function SnapAxisToCellGrid(val, origin, cellSpan)
    local offset = val - origin
    if (cellSpan % 2) == 1 then
        return origin + (math.floor(offset / CELL_CM) + 0.5) * CELL_CM
    else
        return origin + math.floor(offset / CELL_CM + 0.5) * CELL_CM
    end
end

local function SnapWorldToMachineGrid(wx, wy, cellsX, cellsY, yawDeg)
    local rx, ry = GetRotatedCellDims(cellsX or 1, cellsY or 1, yawDeg or 0)
    local sx = SnapAxisToCellGrid(wx, ViewTransform.gridOriginX, rx)
    local sy = SnapAxisToCellGrid(wy, ViewTransform.gridOriginY, ry)
    return sx, sy
end

local function IsPointOverAnyFloorModule(wx, wy, floor)
    if not floor or not floor.platforms then return false end
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        if math.abs(wx - b.cx) <= (b.ex + 10.0) and math.abs(wy - b.cy) <= (b.ey + 10.0) then
            return true, pe
        end
    end
    return false, nil
end

local function IsFootprintBlockedByWall(sx, sy, cellsX, cellsY, yawDeg, floor)
    if not floor or not floor.walls or #floor.walls == 0 then return false end
    local rx, ry = GetRotatedCellDims(cellsX or 1, cellsY or 1, yawDeg or 0)
    local halfW = math.max(10.0, rx * CELL_CM * 0.5 - 6.0)
    local halfH = math.max(10.0, ry * CELL_CM * 0.5 - 6.0)
    local minX, maxX = sx - halfW, sx + halfW
    local minY, maxY = sy - halfH, sy + halfH
    for _, w in ipairs(floor.walls) do
        if maxX > w.minX and minX < w.maxX and maxY > w.minY and minY < w.maxY then
            return true
        end
    end
    return false
end

local function FindPlatformAtWorldXY(wx, wy, floor)
    if not floor or not floor.platforms then return nil, nil end
    local bestPlat, bestBounds = nil, nil
    local bestDist = math.huge
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        local dx = math.abs(wx - b.cx)
        local dy = math.abs(wy - b.cy)
        if dx <= b.ex and dy <= b.ey then
            return pe.platform, b
        end
        local d2 = dx * dx + dy * dy
        if d2 < bestDist then
            bestDist = d2
            bestPlat = pe.platform
            bestBounds = b
        end
    end
    return bestPlat, bestBounds
end

local function GetMachineClassKey(machine, buildableOpt)
    local actor = Core.IsValidObj(machine) and StationData.GetObjectActor(machine) or nil
    if Core.IsValidObj(actor) then
        local okC, cls = pcall(function() return actor:GetClass() end)
        if okC and Core.IsValidObj(cls) then
            local p = SafeFullPath(cls)
            if p then return p, actor, cls end
        end
    end
    if Core.IsValidObj(buildableOpt) then
        local okAC, aCls = pcall(function() return buildableOpt.ActorClass or buildableOpt.PreviewClass or buildableOpt.BlockClass end)
        if okAC and Core.IsValidObj(aCls) then
            local p = SafeFullPath(aCls)
            if p then return p, nil, aCls end
        end
        local bp = SafeFullPath(buildableOpt)
        if bp then return "bld:" .. bp, nil, nil end
    end
    if Core.IsValidObj(machine) then
        local okC, cls = pcall(function() return machine:GetClass() end)
        if okC and Core.IsValidObj(cls) then
            local p = SafeFullPath(cls)
            if p then return "sim:" .. p, nil, nil end
        end
    end
    return nil, nil, nil
end

local function GetColorForMachine(cat)
    if cat == "Assembler" then return COLORS.Assembler
    elseif cat == "Container" then return COLORS.Container
    elseif cat == "Conveyor" then return COLORS.Conveyor
    else return COLORS.OtherMachine end
end

local function IsMajorNonConveyorMachine(machine, cat)
    if cat == "Assembler" or cat == "Container" then
        return true
    end
    if Core.IsValidObj(machine) then
        local okHas = false
        pcall(function()
            if machine.Recipe ~= nil or machine.GetInventory ~= nil or machine.Inventory ~= nil then
                okHas = true
            end
        end)
        if okHas and cat ~= "Conveyor" then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- 2D Machine Visuals, Type Colors & Tier Shading
--------------------------------------------------------------------------------

local TYPE_BASE_COLORS = {
    { pat = "assembler",   col = { R = 0.24, G = 0.62, B = 0.92 } }, -- Light Blue -> Dark Blue by tier
    { pat = "smelter",     col = { R = 0.90, G = 0.45, B = 0.16 } }, -- Orange
    { pat = "furnace",     col = { R = 0.90, G = 0.45, B = 0.16 } },
    { pat = "refinery",    col = { R = 0.88, G = 0.68, B = 0.16 } }, -- Gold-Amber
    { pat = "chemical",    col = { R = 0.84, G = 0.72, B = 0.18 } },
    { pat = "fabricator",  col = { R = 0.16, G = 0.76, B = 0.68 } }, -- Teal
    { pat = "constructor", col = { R = 0.16, G = 0.76, B = 0.68 } },
    { pat = "foundry",     col = { R = 0.86, G = 0.36, B = 0.22 } },
    { pat = "container",   col = { R = 0.46, G = 0.32, B = 0.80 } }, -- Violet-Purple
    { pat = "chest",       col = { R = 0.46, G = 0.32, B = 0.80 } },
    { pat = "storage",     col = { R = 0.46, G = 0.32, B = 0.80 } },
    { pat = "warehouse",   col = { R = 0.46, G = 0.32, B = 0.80 } },
    { pat = "splitter",    col = { R = 0.78, G = 0.30, B = 0.62 } }, -- Magenta
    { pat = "balancer",    col = { R = 0.78, G = 0.30, B = 0.62 } },
    { pat = "merger",      col = { R = 0.78, G = 0.30, B = 0.62 } },
    { pat = "underground", col = { R = 0.34, G = 0.40, B = 0.82 } }, -- Indigo
    { pat = "conveyor",    col = { R = 0.36, G = 0.46, B = 0.58 } }, -- Cool Steel-Slate
    { pat = "belt",        col = { R = 0.36, G = 0.46, B = 0.58 } },
    { pat = "elevator",    col = { R = 0.20, G = 0.72, B = 0.42 } }, -- Emerald Green
    { pat = "miner",       col = { R = 0.24, G = 0.50, B = 0.84 } }, -- Cobalt
    { pat = "drone",       col = { R = 0.24, G = 0.50, B = 0.84 } },
    { pat = "extractor",   col = { R = 0.24, G = 0.50, B = 0.84 } },
    { pat = "turret",      col = { R = 0.82, G = 0.24, B = 0.26 } }, -- Crimson
    { pat = "reactor",     col = { R = 0.54, G = 0.80, B = 0.20 } }, -- Lime Green
    { pat = "generator",   col = { R = 0.54, G = 0.80, B = 0.20 } },
    { pat = "solar",       col = { R = 0.74, G = 0.78, B = 0.18 } },
    { pat = "battery",     col = { R = 0.42, G = 0.76, B = 0.28 } },
    { pat = "dock",        col = { R = 0.62, G = 0.36, B = 0.52 } }, -- Plum
    { pat = "shipyard",    col = { R = 0.62, G = 0.36, B = 0.52 } },
}

local function HsvToRgb(h, s, v)
    local c = v * s
    local hh = (h % 360.0) / 60.0
    local x = c * (1.0 - math.abs((hh % 2.0) - 1.0))
    local m = v - c
    local r, g, b = 0, 0, 0
    if hh < 1.0 then r, g, b = c, x, 0
    elseif hh < 2.0 then r, g, b = x, c, 0
    elseif hh < 3.0 then r, g, b = 0, c, x
    elseif hh < 4.0 then r, g, b = 0, x, c
    elseif hh < 5.0 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    return { R = r + m, G = g + m, B = b + m }
end

local function ComputeBaseColorForType(typeKey)
    for _, rule in ipairs(TYPE_BASE_COLORS) do
        if typeKey:find(rule.pat, 1, true) then
            return rule.col
        end
    end
    local hash = 0
    for i = 1, #typeKey do
        hash = (hash * 37 + string.byte(typeKey, i)) % 360
    end
    return HsvToRgb(hash, 0.62, 0.80)
end

local function GetShadedColorForTypeAndTier(typeKey, tier)
    local base = ComputeBaseColorForType(typeKey or "machine")
    local mult = 1.0
    if tier == 2 then mult = 0.68
    elseif tier == 3 then mult = 0.46
    elseif tier >= 4 then mult = math.max(0.28, 0.46 * (0.72 ^ (tier - 3))) end
    return {
        R = base.R * mult,
        G = base.G * mult,
        B = base.B * mult,
        A = 0.94,
    }, {
        R = math.max(0.05, base.R * mult * 0.52),
        G = math.max(0.05, base.G * mult * 0.52),
        B = math.max(0.05, base.B * mult * 0.52),
        A = 1.0,
    }
end

local function ResetSpriteCache()
    MachineSpriteCache = {}
    MissingIconsLogged = {}
    IconDiagLogged = false
end

local function IsFiniteNum(v)
    return type(v) == "number" and v == v and v > -1e9 and v < 1e9
end

local function RequestMachineSprite(clsKey, machine, cat, buildableOpt)
    if clsKey and MachineSpriteCache[clsKey] then
        return MachineSpriteCache[clsKey]
    end

    local typeKey, tier, dispName = StationData.GetMachineTypeAndTier(machine, buildableOpt)
    local bgCol, borderCol = GetShadedColorForTypeAndTier(typeKey, tier)
    local tex = nil
    if cat ~= "Conveyor" then
        tex = StationData.GetBuildableIconTexture(machine, buildableOpt)
    end
    local directional = (cat == "Conveyor")
        or typeKey:find("conveyor", 1, true) ~= nil
        or typeKey:find("belt", 1, true) ~= nil
        or typeKey:find("splitter", 1, true) ~= nil
        or typeKey:find("balancer", 1, true) ~= nil
        or typeKey:find("merger", 1, true) ~= nil
        or typeKey:find("underground", 1, true) ~= nil

    if not IconDiagLogged and (Core.IsValidObj(machine) or Core.IsValidObj(buildableOpt)) then
        IconDiagLogged = true
        local bld = Core.IsValidObj(buildableOpt) and buildableOpt or (Core.IsValidObj(machine) and pcall(function() return machine.Buildable end) and machine.Buildable or nil)
        Core.Log(string.format("[StationMap] 2DIconSample type=%s tier=%d name=%s bldValid=%s texValid=%s",
            tostring(typeKey), tier, tostring(dispName), tostring(Core.IsValidObj(bld)), tostring(Core.IsValidObj(tex))))
    end
    if cat ~= "Conveyor" and not Core.IsValidObj(tex) and clsKey and not MissingIconsLogged[clsKey] then
        MissingIconsLogged[clsKey] = true
        local hasBld = Core.IsValidObj(buildableOpt) or (Core.IsValidObj(machine) and pcall(function() return Core.IsValidObj(machine.Buildable) end) and Core.IsValidObj(machine.Buildable))
        Core.Log(string.format("[StationMap] Missing2DIcon cls=%s type=%s tier=%d name=%s bldValid=%s",
            tostring(clsKey), tostring(typeKey), tier, tostring(dispName), tostring(hasBld)))
    end

    local entry = {
        tex = tex,
        bgCol = bgCol,
        borderCol = borderCol,
        typeKey = typeKey,
        tier = tier,
        directional = directional,
        fullTileTex = false,
    }
    if clsKey then
        MachineSpriteCache[clsKey] = entry
    end
    return entry
end

--------------------------------------------------------------------------------
-- Build Command & Inventory Helpers
--------------------------------------------------------------------------------

local CachedBuildCmdLayout = nil
local BuildCmdSigLogged = false
local ApplyInProgress = false

local function InspectBuildMachineCommandLayout()
    if CachedBuildCmdLayout ~= nil then
        return CachedBuildCmdLayout or nil
    end
    local ufunc = StaticFindObject("/Script/MainSequence.DMSPlayerController:AddBuildMachineCommand")
    if not Core.IsValidObj(ufunc) then
        CachedBuildCmdLayout = false
        if not BuildCmdSigLogged then
            BuildCmdSigLogged = true
            Core.Log("[StationMap] BuildCmdSig: AddBuildMachineCommand not found")
        end
        return nil
    end

    local layout = { params = {}, firstStructFields = nil, firstStructName = nil }
    local sigParts = {}
    pcall(function()
        ufunc:ForEachProperty(function(prop)
            local pName = prop:GetFName():ToString()
            local pCls = ""
            pcall(function() pCls = prop:GetClass():GetFName():ToString() end)
            local isRet = (pName == "ReturnValue")
            if not isRet then
                local pInfo = { name = pName, cls = pCls, structName = nil, fields = nil }
                if pCls == "StructProperty" and prop.GetStruct then
                    local okS, st = pcall(function() return prop:GetStruct() end)
                    if okS and Core.IsValidObj(st) then
                        pcall(function() pInfo.structName = st:GetFName():ToString() end)
                        if st.ForEachProperty then
                            local fMap = {}
                            local fStructMap = {}
                            local fList = {}
                            st:ForEachProperty(function(fp)
                                local fName = fp:GetFName():ToString()
                                local fCls = ""
                                pcall(function() fCls = fp:GetClass():GetFName():ToString() end)
                                fMap[fName] = fCls
                                local fSub = ""
                                if fCls == "StructProperty" and fp.GetStruct then
                                    local okFS, fst = pcall(function() return fp:GetStruct() end)
                                    if okFS and Core.IsValidObj(fst) then
                                        pcall(function() fSub = fst:GetFName():ToString() end)
                                        if fSub ~= "" then fStructMap[fName] = fSub end
                                    end
                                end
                                table.insert(fList, fName .. ":" .. fCls .. (fSub ~= "" and ("(" .. fSub .. ")") or ""))
                            end)
                            pInfo.fields = fMap
                            pInfo.fieldStructs = fStructMap
                            if not layout.firstStructFields then
                                layout.firstStructName = pName
                                layout.firstStructFields = fMap
                                layout.firstStructFieldTypes = fStructMap
                            end
                            table.insert(sigParts, string.format("%s(%s:%s{%s})", pName, pCls, tostring(pInfo.structName), table.concat(fList, ",")))
                        else
                            table.insert(sigParts, string.format("%s(%s:%s)", pName, pCls, tostring(pInfo.structName)))
                        end
                    else
                        table.insert(sigParts, string.format("%s(%s)", pName, pCls))
                    end
                else
                    table.insert(sigParts, string.format("%s(%s)", pName, pCls))
                end
                table.insert(layout.params, pInfo)
            end
        end)
    end)

    if not BuildCmdSigLogged then
        BuildCmdSigLogged = true
        Core.Log("[StationMap] BuildCmdSig: params(" .. #layout.params .. ")=[" .. table.concat(sigParts, "; ") .. "]")
        -- Also list all build/command-related UFunctions on DMSPlayerController & Builder for diagnostics
        local fnNames = {}
        pcall(function()
            local pc = Core.GetLocalPlayerController()
            local function scanFuncs(tag, obj)
                if not Core.IsValidObj(obj) then return end
                local c = obj:GetClass()
                local d = 0
                while Core.IsValidObj(c) and d < 5 do
                    d = d + 1
                    if c.ForEachFunction then
                        c:ForEachFunction(function(fn)
                            local n = fn:GetFName():ToString()
                            local low = n:lower()
                            if low:find("build", 1, true) or low:find("command", 1, true) or low:find("machine", 1, true) then
                                table.insert(fnNames, tag .. ":" .. n)
                            end
                        end)
                    end
                    c = c.GetSuperStruct and c:GetSuperStruct() or nil
                end
            end
            scanFuncs("PC", pc)
            if Core.IsValidObj(pc) and Core.IsValidObj(pc.Builder) then
                scanFuncs("Builder", pc.Builder)
            end
        end)
        Core.Log("[StationMap] BuildFuncs: " .. table.concat(fnNames, ", "))

        -- Inspect a real placed machine on the current floor to see exact GridLocation / Height / PlatformID / Rotation units
        local refParts = {}
        pcall(function()
            local fl = CurrentFloors[SelectedFloorIdx] or CurrentFloors[1]
            local sampleM = nil
            if fl and fl.machines then
                for _, me in ipairs(fl.machines) do
                    if Core.IsValidObj(me.machine) and StationData.GetMachineCategory(me.machine) ~= "Conveyor" then
                        sampleM = me
                        break
                    end
                end
            end
            if sampleM and Core.IsValidObj(sampleM.machine) then
                local m = sampleM.machine
                table.insert(refParts, string.format("cls=%s local=(%.0f,%.0f,%.0f) yaw=%.0f",
                    m:GetClass():GetFName():ToString(), sampleM.x or 0, sampleM.y or 0, sampleM.z or 0, sampleM.yaw or 0))
                local c = m:GetClass()
                local d = 0
                local seenP = {}
                while Core.IsValidObj(c) and d < 6 do
                    d = d + 1
                    if c.ForEachProperty then
                        c:ForEachProperty(function(p)
                            local pn = p:GetFName():ToString()
                            if not seenP[pn] then
                                seenP[pn] = true
                                local low = pn:lower()
                                if low:find("grid", 1, true) or low:find("height", 1, true) or low:find("plat", 1, true)
                                    or low:find("rot", 1, true) or low:find("loc", 1, true) or low:find("config", 1, true)
                                    or low == "id" or low:find("frame", 1, true)
                                then
                                    local okV, val = pcall(function() return m[pn] end)
                                    if okV and val ~= nil then
                                        if type(val) == "number" or type(val) == "boolean" or type(val) == "string" then
                                            table.insert(refParts, pn .. "=" .. tostring(val))
                                        elseif type(val) == "userdata" then
                                            local okXY, vx, vy, vz = pcall(function()
                                                if val.X ~= nil and val.Y ~= nil then
                                                    local a, b, z = Core.GetFPVector(val)
                                                    return a, b, z
                                                end
                                                return nil
                                            end)
                                            if okXY and vx ~= nil then
                                                table.insert(refParts, string.format("%s=(%.1f,%.1f,%.1f)", pn, vx, vy, vz or 0))
                                            elseif Core.IsValidObj(val) then
                                                local okId, vid = pcall(function() return val.ID end)
                                                table.insert(refParts, string.format("%s=%s(id=%s)", pn, val:GetClass():GetFName():ToString(), tostring(okId and vid or "?")))
                                            end
                                        end
                                    end
                                end
                            end
                        end)
                    end
                    c = c.GetSuperStruct and c:GetSuperStruct() or nil
                end
                -- Inspect m.GridTransform struct fields & calibrate BuildGridDivisor / BuildHeightDivisor
                pcall(function()
                    local gt = m.GridTransform
                    if gt then
                        local gtParts = {}
                        local gtSt = Core.UnwrapStruct(gt) or gt
                        local gtStructObj = nil
                        pcall(function()
                            local mc = m:GetClass()
                            local md = 0
                            while Core.IsValidObj(mc) and md < 6 and not gtStructObj do
                                md = md + 1
                                if mc.ForEachProperty then
                                    mc:ForEachProperty(function(mp)
                                        if not gtStructObj and mp:GetFName():ToString() == "GridTransform" and mp.GetStruct then
                                            local okS, st = pcall(function() return mp:GetStruct() end)
                                            if okS and Core.IsValidObj(st) then gtStructObj = st end
                                        end
                                    end)
                                end
                                mc = mc.GetSuperStruct and mc:GetSuperStruct() or nil
                            end
                        end)
                        local function inspectGtField(fn)
                            local okF, fv = pcall(function() return gtSt[fn] end)
                            if not okF or fv == nil then return end
                            if type(fv) == "number" or type(fv) == "boolean" then
                                table.insert(gtParts, fn .. "=" .. tostring(fv))
                                local fl = fn:lower()
                                if (fl == "height" or fl == "z") and math.abs(sampleM.z or 0) >= 100.0 and math.abs(fv) > 0.01 then
                                    BuildHeightDivisor = math.abs((sampleM.z or 0) / fv)
                                    GridCalibrated = true
                                end
                            elseif type(fv) == "userdata" then
                                local okXY, gx0, gy0 = pcall(function()
                                    if fv.X ~= nil and fv.Y ~= nil then
                                        local ax = Core.GetFPFloat(fv.X)
                                        local ay = Core.GetFPFloat(fv.Y)
                                        return ax, ay
                                    end
                                    return nil
                                end)
                                if okXY and gx0 ~= nil then
                                    table.insert(gtParts, string.format("%s=(%.1f,%.1f)", fn, gx0, gy0))
                                    if math.abs(sampleM.x or 0) >= 100.0 and math.abs(gx0) > 0.01 then
                                        BuildGridDivisor = math.abs((sampleM.x or 0) / gx0)
                                        GridCalibrated = true
                                    elseif math.abs(sampleM.y or 0) >= 100.0 and math.abs(gy0) > 0.01 then
                                        BuildGridDivisor = math.abs((sampleM.y or 0) / gy0)
                                        GridCalibrated = true
                                    end
                                end
                            end
                        end
                        if Core.IsValidObj(gtStructObj) and gtStructObj.ForEachProperty then
                            gtStructObj:ForEachProperty(function(fp)
                                inspectGtField(fp:GetFName():ToString())
                            end)
                        else
                            for _, fn in ipairs({ "Location", "GridLocation", "Position", "Height", "Z", "Rotation", "Yaw", "PlatformID" }) do
                                inspectGtField(fn)
                            end
                        end
                        Core.Log(string.format("[StationMap] RefGridTransform: [%s] -> gridDiv=%.1f heightDiv=%.1f",
                            table.concat(gtParts, ", "), BuildGridDivisor, BuildHeightDivisor))
                    end
                end)
            end
        end)
        Core.Log("[StationMap] RefMachineProps: " .. table.concat(refParts, ", "))
    end

    CachedBuildCmdLayout = layout
    return layout
end

local function PlayerHasBuildableMaterials(pc, buildable, count)
    if not Core.IsValidObj(pc) or not Core.IsValidObj(buildable) then return false end
    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return false end

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
        local st = Core.UnwrapStruct(elem)
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

local function CheckMaterialsForPendingList(pc, list)
    local counts = {}
    local buildables = {}
    for _, g in ipairs(list) do
        if Core.IsValidObj(g.buildable) then
            local addr = g.buildable:GetAddress()
            counts[addr] = (counts[addr] or 0) + 1
            buildables[addr] = g.buildable
        end
    end
    for addr, cnt in pairs(counts) do
        if not PlayerHasBuildableMaterials(pc, buildables[addr], cnt) then
            return false, buildables[addr]
        end
    end
    return true, nil
end

local function IssueRemoteBuildMachine(pc, station, platform, platBounds, buildable, locX, locY, locZ, wx, wy, wz, yawDeg, recipe)
    if not (Core.IsValidObj(pc) and Core.IsValidObj(buildable)) then
        return false, "Invalid controller or buildable"
    end
    if not PlayerHasBuildableMaterials(pc, buildable, 1) then
        return false, "Insufficient materials in inventory"
    end

    local targetFrame = Core.IsValidObj(station) and station or platform
    if not Core.IsValidObj(targetFrame) then
        return false, "No target station"
    end

    local layout = InspectBuildMachineCommandLayout()
    if not layout or #layout.params == 0 then
        return false, "Build command unavailable (see UE4SS.log)"
    end

    local quat = {
        X = 0.0,
        Y = 0.0,
        Z = math.sin(math.rad((yawDeg or 0.0) * 0.5)),
        W = math.cos(math.rad((yawDeg or 0.0) * 0.5)),
    }
    local localTransform = {
        Rotation = quat,
        Translation = { X = locX, Y = locY, Z = locZ },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local worldTransform = {
        Rotation = quat,
        Translation = { X = wx, Y = wy, Z = wz },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local frameId = 0
    pcall(function() if targetFrame.ID ~= nil then frameId = tonumber(targetFrame.ID) or 0 end end)
    local platId = 0
    if Core.IsValidObj(platform) then
        pcall(function() if platform.ID ~= nil then platId = tonumber(platform.ID) or 0 end end)
    end
    local gx = math.floor(locX / BuildGridDivisor + 0.5)
    local gy = math.floor(locY / BuildGridDivisor + 0.5)
    local gz = math.floor(locZ / BuildHeightDivisor + 0.5)
    local rotSteps = ((math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4) + 4) % 4

    local cmdSuccess = false
    local callErr = nil

    if #layout.params == 1 and layout.params[1].fields then
        -- Single struct command parameter (BuildMachineCommand): populate fields strictly by reflected type
        local cmd = {}
        local fields = layout.params[1].fields
        local fStructs = layout.params[1].fieldStructs or {}
        local populated = 0
        local hasBuildable = false
        local function setIfField(name, val, reqClsSub)
            local fCls = fields[name]
            if fCls ~= nil and val ~= nil and (not reqClsSub or fCls:find(reqClsSub, 1, true)) then
                cmd[name] = val
                populated = populated + 1
                if name == "Buildable" or name == "BuildBlock" then hasBuildable = true end
            end
        end
        local glStruct = (fStructs["GridLocation"] or ""):lower()
        local gridLocVal = (glStruct:find("intpoint", 1, true) or fields["Height"] ~= nil)
            and { X = gx, Y = gy }
            or { X = gx, Y = gy, Z = gz }
        -- Prefer station/frame ID (UStationObject.ID) over subobject block ID for PlatformID
        local targetPlatId = (frameId and frameId ~= 0) and frameId or platId

        setIfField("FrameID", frameId, "Int")
        setIfField("StationID", frameId, "Int")
        setIfField("Frame", targetFrame, "Object")
        setIfField("Station", targetFrame, "Object")
        setIfField("PlatformID", targetPlatId, "Int")
        setIfField("Platform", platform, "Object")
        setIfField("Buildable", buildable, "Object")
        setIfField("BuildBlock", buildable, "Object")
        setIfField("GridLocation", gridLocVal, "Struct")
        setIfField("Height", gz, "Int")
        setIfField("GridRotation", rotSteps, "Int")
        if fields["Rotation"] and fields["Rotation"]:find("Int", 1, true) then
            setIfField("Rotation", rotSteps, "Int")
        else
            setIfField("Rotation", { Pitch = 0.0, Yaw = yawDeg or 0.0, Roll = 0.0 }, "Struct")
        end
        setIfField("Config", 0, "Int")
        setIfField("Yaw", yawDeg or 0.0, "Float")
        setIfField("LocalQuat", quat, "Struct")
        setIfField("Quat", quat, "Struct")
        setIfField("Transform", localTransform, "Struct")
        setIfField("Location", { X = locX, Y = locY, Z = locZ }, "Struct")

        if hasBuildable and populated >= 2 then
            Core.Log(string.format("[StationMap] Calling AddBuildMachineCommand(platId=%d [stationId=%d,subId=%d], grid=(%d,%d), h=%d, rot=%d, fields=%d)",
                targetPlatId, frameId, platId, gx, gy, gz, rotSteps, populated))
            local okCmd, errCmd = pcall(function() pc:AddBuildMachineCommand(cmd) end)
            Core.Log(string.format("[StationMap] AddBuildMachineCommand returned ok=%s err=%s", tostring(okCmd), tostring(errCmd)))
            if okCmd then
                cmdSuccess = true
            else
                callErr = tostring(errCmd)
            end
        else
            callErr = string.format("Struct fields mismatch (populated=%d, hasBuildable=%s; see BuildCmdSig in UE4SS.log)", populated, tostring(hasBuildable))
        end
    else
        -- Multi-parameter signature: map each parameter strictly by inspected name & type (no blind fuzzing)
        local args = {}
        local allMatched = true
        for _, p in ipairs(layout.params) do
            local low = p.name:lower()
            local cls = p.cls or ""
            local val = nil
            if cls:find("Object", 1, true) then
                if low:find("build", 1, true) or low:find("machine", 1, true) then
                    val = buildable
                elseif low:find("plat", 1, true) then
                    val = Core.IsValidObj(platform) and platform or targetFrame
                elseif low:find("frame", 1, true) or low:find("station", 1, true) or low:find("parent", 1, true) then
                    val = targetFrame
                end
            elseif cls:find("Int", 1, true) then
                if low:find("rot", 1, true) or low:find("dir", 1, true) then
                    val = rotSteps
                elseif low:find("plat", 1, true) then
                    val = platId
                elseif low:find("frame", 1, true) or low:find("station", 1, true) or low:find("id", 1, true) then
                    val = frameId
                end
            elseif cls:find("Float", 1, true) or cls:find("Double", 1, true) then
                if low:find("yaw", 1, true) or low:find("rot", 1, true) or low:find("ang", 1, true) then
                    val = yawDeg or 0.0
                end
            elseif cls:find("Bool", 1, true) then
                val = false
            elseif cls:find("Struct", 1, true) then
                local sn = (p.structName or ""):lower()
                if sn:find("transform", 1, true) then
                    val = low:find("world", 1, true) and worldTransform or localTransform
                elseif sn:find("intvector", 1, true) then
                    val = { X = gx, Y = gy, Z = gz }
                elseif sn:find("intpoint", 1, true) then
                    val = { X = gx, Y = gy }
                elseif sn:find("rotator", 1, true) then
                    val = { Pitch = 0.0, Yaw = yawDeg or 0.0, Roll = 0.0 }
                elseif sn:find("quat", 1, true) then
                    val = quat
                elseif sn:find("vector", 1, true) then
                    val = low:find("world", 1, true) and { X = wx, Y = wy, Z = wz } or { X = locX, Y = locY, Z = locZ }
                end
            end
            if val == nil then
                allMatched = false
                callErr = "Unmapped build param: " .. p.name .. "(" .. cls .. ":" .. tostring(p.structName) .. ")"
                break
            end
            table.insert(args, val)
        end

        if allMatched then
            Core.Log(string.format("[StationMap] Calling AddBuildMachineCommand(args=%d, loc=(%.0f,%.0f,%.0f))", #args, locX, locY, locZ))
            local okCmd, errCmd = pcall(function() pc:AddBuildMachineCommand(table.unpack(args)) end)
            if okCmd then
                cmdSuccess = true
            else
                callErr = tostring(errCmd)
            end
        end
    end

    if not cmdSuccess then
        Core.Log("[StationMap] IssueRemoteBuildMachine failed: " .. tostring(callErr))
        return false, callErr or "Build command failed (see UE4SS.log)"
    end

    if Core.IsValidObj(recipe) then
        ExecuteInGameThreadWithDelay(250, function()
            StationData.InvalidateCaches()
            local machines = StationData.GetAllStationMachines(CurrentStation, { platform }, CurrentWalkFrame)
            local bestM, bestDist = nil, 150.0
            for _, m in ipairs(machines) do
                if StationData.GetMachineCategory(m) == "Assembler" then
                    local mx, my = StationData.GetMachineWorldPosAndYaw(m, platBounds)
                    local d = math.sqrt((mx - wx) ^ 2 + (my - wy) ^ 2)
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
-- UI Creation & Rendering
--------------------------------------------------------------------------------

local function ClearCanvasChildren(canvas)
    if Core.IsValidObj(canvas) then
        pcall(function() canvas:ClearChildren() end)
    end
end

local function SetImageWidgetOpacity(img, col)
    if not Core.IsValidObj(img) then return end
    pcall(function()
        if img.SetColorAndOpacity then
            img:SetColorAndOpacity(col)
        elseif img.SetBrushTintColor then
            img:SetBrushTintColor({ SpecifiedColor = col, ColorUseRule = 0 })
        end
    end)
end

-- Creates a reliable clickable button backed by WBP_Button_C (using Overlay instead of broken SetContentForSlot)
local function CreateLabeledButton(parentWindow, pc, outer, labelStr, fontSz, widthOpt, heightOpt, bgCol, textCol, onClick, trackList)
    local btn = Core.CreateUserWidget(PATHS.WBPButtonClass, parentWindow, pc)
    local txt = Core.CreateUserWidget(PATHS.WBPTextClass, parentWindow, pc)
    local ov = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    if not (Core.IsValidObj(btn) and Core.IsValidObj(txt) and Core.IsValidObj(ov)) then
        return nil, nil, nil
    end

    pcall(function()
        if bgCol and btn.SetBackgroundColour then
            btn:SetBackgroundColour(bgCol)
        end
        btn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        local bSlot = ov:AddChildToOverlay(btn)
        if Core.IsValidObj(bSlot) then
            bSlot:SetHorizontalAlignment(0) -- Fill
            bSlot:SetVerticalAlignment(0)   -- Fill
        end

        local tSlot = ov:AddChildToOverlay(txt)
        if Core.IsValidObj(tSlot) then
            tSlot:SetHorizontalAlignment(2) -- Center
            tSlot:SetVerticalAlignment(2)   -- Center
            tSlot:SetPadding({ Left = 6.0, Top = 2.0, Right = 6.0, Bottom = 2.0 })
        end
        -- Re-apply size/text/visibility AFTER parenting (WBP_Text_C Construct resets defaults on parent attach)
        local function ApplyTextProps()
            if not Core.IsValidObj(txt) then return end
            pcall(function()
                txt:SetVisibility(3) -- HitTestInvisible so clicks reach WBP_Button_C underneath
                if Core.IsValidObj(txt.TextBlock) then
                    txt.TextBlock:SetVisibility(3)
                end
                txt:SetSize(fontSz or 12)
                txt:SetText(Core.MakeText(labelStr or ""))
                if textCol and Core.IsValidObj(txt.TextBlock) and txt.TextBlock.SetColorAndOpacity then
                    txt.TextBlock:SetColorAndOpacity({ SpecifiedColor = textCol, ColorUseRule = 0 })
                end
            end)
        end
        ApplyTextProps()
        ExecuteInGameThreadAfterFrames(1, ApplyTextProps)
    end)

    Core.RegisterWBPButtonClick(btn, onClick)
    table.insert(trackList or TrackedButtons, btn)

    if widthOpt or heightOpt then
        local sb = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
        if Core.IsValidObj(sb) then
            pcall(function()
                if widthOpt then sb:SetWidthOverride(widthOpt) end
                if heightOpt then sb:SetHeightOverride(heightOpt) end
                sb:AddChild(ov)
            end)
            return sb, btn, txt
        end
    end
    return ov, btn, txt
end

local BELT_TIER_COLORS = {
    [1] = { R = 0.98, G = 0.84, B = 0.12, A = 1.0 }, -- Mk1: Yellow
    [2] = { R = 0.96, G = 0.48, B = 0.08, A = 1.0 }, -- Mk2: Orange
    [3] = { R = 0.90, G = 0.18, B = 0.16, A = 1.0 }, -- Mk3: Red
}

local function GetTierArrowColor(tier)
    local t = tonumber(tier) or 1
    if t <= 1 then return BELT_TIER_COLORS[1]
    elseif t == 2 then return BELT_TIER_COLORS[2]
    else return BELT_TIER_COLORS[3] end
end

local function AddSharpChevronToCanvas(outer, canvas, tipX, cy, armLen, armThick, col, zBase)
    -- Two 42-deg arms whose right tips intersect cleanly at (tipX, cy) forming a crisp V chevron (>)
    local rad = math.rad(42.0)
    local halfCos = (armLen * 0.5) * math.cos(rad)
    local halfSin = (armLen * 0.5) * math.sin(rad)
    local cx = tipX - halfCos
    for _, sp in ipairs({ { dy = -halfSin, ang = 42.0 }, { dy = halfSin, ang = -42.0 } }) do
        local bar = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if Core.IsValidObj(bar) then
            pcall(function()
                bar:SetVisibility(3)
                bar:SetBrushColor(col)
                bar:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                if bar.SetRenderTransformAngle then bar:SetRenderTransformAngle(sp.ang) end
            end)
            local bs = canvas:AddChildToCanvas(bar)
            SetCanvasSlot(bs, cx, cy + sp.dy, armLen, armThick, 0.5, 0.5, zBase)
        end
    end
end

local function RenderDirectionChevron(outer, canvas, cx, cy, sizePx, yawDeg, col, zOrder)
    local s = math.max(10.0, sizePx or 18.0)
    local tile = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    if not Core.IsValidObj(tile) then return nil end
    pcall(function()
        tile:SetVisibility(3)
        tile:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        if math.abs(yawDeg or 0.0) > 0.1 and tile.SetRenderTransformAngle then
            tile:SetRenderTransformAngle(yawDeg)
        end
    end)
    local tSlot = canvas:AddChildToCanvas(tile)
    SetCanvasSlot(tSlot, cx, cy, s, s, 0.5, 0.5, zOrder)

    local armLen = math.max(6.0, s * 0.44)
    local armThick = math.max(1.8, math.min(3.2, s * 0.12))
    AddSharpChevronToCanvas(outer, tile, s * 0.68, s * 0.5, armLen, armThick, col, 1)
    return tile
end

local PORT_BG_COL = { R = 0.0, G = 0.0, B = 0.0, A = 0.56 }
local PORT_DASH_COL = { R = 0.0, G = 0.0, B = 0.0, A = 0.98 }
local function RenderUnconnectedItemPort(outer, canvas, px, py, portSize, zOrder)
    local sz = math.max(12.0, portSize or 18.0)
    local half = sz * 0.5

    AddBorderFast(outer, canvas, px, py, sz - 2.0, sz - 2.0, PORT_BG_COL, zOrder)

    -- True multi-dash thick black border (3 distinct dashes along each of the 4 sides)
    local thick = math.max(1.8, sz * 0.11)
    local dashLen = math.max(2.6, sz * 0.21)
    local step = sz * 0.34
    local zDash = zOrder + 1
    for _, off in ipairs({ -step, 0.0, step }) do
        AddBorderFast(outer, canvas, px + off, py - half, dashLen, thick, PORT_DASH_COL, zDash)
        AddBorderFast(outer, canvas, px + off, py + half, dashLen, thick, PORT_DASH_COL, zDash)
        AddBorderFast(outer, canvas, px - half, py + off, thick, dashLen, PORT_DASH_COL, zDash)
        AddBorderFast(outer, canvas, px + half, py + off, thick, dashLen, PORT_DASH_COL, zDash)
    end
end

local function RenderDashedLine(outer, canvas, x1, y1, x2, y2, col, thickness, dashLen, gapLen, zOrder)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 4.0 then return end
    local ang = math.deg(math.atan(dy, dx))
    local dLen = dashLen or 10.0
    local gLen = gapLen or 7.0
    local step = dLen + gLen
    local ux, uy = dx / dist, dy / dist
    local t = 4.0
    while t < dist - 4.0 do
        local segLen = math.min(dLen, (dist - 4.0) - t)
        if segLen >= 2.0 then
            local mid = t + segLen * 0.5
            local b = Core.CreateRawWidget(PATHS.BorderClass, outer)
            if Core.IsValidObj(b) then
                pcall(function()
                    b:SetVisibility(3)
                    b:SetBrushColor(col)
                    b:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                    if math.abs(ang) > 0.1 and b.SetRenderTransformAngle then b:SetRenderTransformAngle(ang) end
                end)
                local bs = canvas:AddChildToCanvas(b)
                SetCanvasSlot(bs, x1 + ux * mid, y1 + uy * mid, segLen, thickness or 2.4, 0.5, 0.5, zOrder)
            end
        end
        t = t + step
    end
end

local function CreateMachineVisualWidget(parentWindow, pc, outer, targetCanvas, mx, my, pxW, pxH, yawDeg, cat, spriteEntry, isGhost, validGhost, zBase, hasBottomOverlay)
    local fillW = math.max(6.0, pxW - 2.0)
    local fillH = math.max(6.0, pxH - 2.0)

    -- Dedicated crisp 2D conveyor belt visual: darker gray belt bed, black/dark-gray guide rails, sharp tier chevrons
    if cat == "Conveyor" then
        local tier = (spriteEntry and spriteEntry.tier) or 1
        local tierDark = (tier == 1) and 1.0 or ((tier == 2) and 0.78 or 0.62)
        local bgCol = isGhost and (validGhost and COLORS.GhostValid or COLORS.GhostInvalid)
            or { R = 0.22 * tierDark, G = 0.24 * tierDark, B = 0.27 * tierDark, A = 0.96 }
        local bdrCol = isGhost and (validGhost and COLORS.GhostBorderOk or COLORS.GhostBorderBad)
            or { R = 0.06, G = 0.07, B = 0.09, A = 0.98 }
        local railCol = isGhost and bdrCol or { R = 0.05, G = 0.06, B = 0.08, A = 0.98 }
        local arrowCol = isGhost and bdrCol or GetTierArrowColor(tier)

        local tile = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
        if Core.IsValidObj(tile) then
            pcall(function()
                tile:SetVisibility(3)
                tile:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                if math.abs(yawDeg or 0.0) > 0.1 and tile.SetRenderTransformAngle then
                    tile:SetRenderTransformAngle(yawDeg)
                end
            end)
            local ts = targetCanvas:AddChildToCanvas(tile)
            SetCanvasSlot(ts, mx, my, pxW, pxH, 0.5, 0.5, zBase)

            local railThick = math.max(2.0, fillH * 0.12)
            local railBase = Core.CreateRawWidget(PATHS.BorderClass, outer)
            if Core.IsValidObj(railBase) then
                pcall(function() railBase:SetVisibility(3); railBase:SetBrushColor(railCol) end)
                local rs = tile:AddChildToCanvas(railBase)
                SetCanvasSlot(rs, pxW * 0.5, pxH * 0.5, fillW, fillH, 0.5, 0.5, 1)
            end

            local bg = Core.CreateRawWidget(PATHS.BorderClass, outer)
            if Core.IsValidObj(bg) then
                pcall(function() bg:SetVisibility(3); bg:SetBrushColor(bgCol) end)
                local bs = tile:AddChildToCanvas(bg)
                SetCanvasSlot(bs, pxW * 0.5, pxH * 0.5, fillW, math.max(4.0, fillH - railThick * 2.0), 0.5, 0.5, 2)
            end

            -- Two sharp apex-aligned chevrons (>>) pointing along +X (yaw=0)
            local armLen = math.max(5.5, pxW * 0.25)
            local armThick = math.max(1.6, math.min(2.6, pxH * 0.055))
            AddSharpChevronToCanvas(outer, tile, pxW * 0.43, pxH * 0.5, armLen, armThick, arrowCol, 3)
            AddSharpChevronToCanvas(outer, tile, pxW * 0.75, pxH * 0.5, armLen, armThick, arrowCol, 3)
            return tile
        end
    end

    local bgCol = (spriteEntry and spriteEntry.bgCol) or GetColorForMachine(cat)
    local bdrCol = (spriteEntry and spriteEntry.borderCol) or { R = 0.08, G = 0.10, B = 0.14, A = 1.0 }
    if isGhost then
        bgCol = validGhost and COLORS.GhostValid or COLORS.GhostInvalid
        bdrCol = validGhost and COLORS.GhostBorderOk or COLORS.GhostBorderBad
    end

    -- Outer subtle frame border + full-footprint colored fill covering the entire machine rectangle
    local bdrBox = Core.CreateRawWidget(PATHS.BorderClass, outer)
    if Core.IsValidObj(bdrBox) then
        pcall(function()
            bdrBox:SetVisibility(3)
            bdrBox:SetBrushColor(bdrCol)
        end)
        local bs = targetCanvas:AddChildToCanvas(bdrBox)
        SetCanvasSlot(bs, mx, my, math.max(6.0, pxW), math.max(6.0, pxH), 0.5, 0.5, zBase)
    end

    local fillBox = Core.CreateRawWidget(PATHS.BorderClass, outer)
    if Core.IsValidObj(fillBox) then
        pcall(function()
            fillBox:SetVisibility(3)
            fillBox:SetBrushColor(bgCol)
        end)
        local fs = targetCanvas:AddChildToCanvas(fillBox)
        SetCanvasSlot(fs, mx, my, fillW, fillH, 0.5, 0.5, zBase + 1)
    end

    -- Centered 2D build-menu machine asset inside the colored rectangle
    if spriteEntry and Core.IsValidObj(spriteEntry.tex) then
        local img = Core.CreateRawWidget(PATHS.ImageClass, outer)
        if Core.IsValidObj(img) then
            local shiftUp = (hasBottomOverlay and pxH >= 52.0)
            local iconDim
            if spriteEntry.fullTileTex then
                iconDim = math.max(6.0, math.min(fillW, fillH))
            else
                local availH = shiftUp and (fillH * 0.56) or (fillH * 0.82)
                local availW = fillW * 0.82
                iconDim = math.max(6.0, math.min(availW, availH))
            end
            local iconY = shiftUp and (my - fillH * 0.17) or my
            pcall(function()
                img:SetVisibility(3)
                img:SetBrushFromTexture(spriteEntry.tex, false)
                if isGhost then
                    SetImageWidgetOpacity(img, validGhost and { R = 0.85, G = 1.0, B = 1.0, A = 0.72 } or { R = 1.0, G = 0.5, B = 0.5, A = 0.72 })
                else
                    SetImageWidgetOpacity(img, { R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
                end
                if spriteEntry.directional and math.abs(yawDeg or 0.0) > 0.1 and img.SetRenderTransformAngle then
                    img:SetRenderTransformAngle(yawDeg)
                end
            end)
            local islot = targetCanvas:AddChildToCanvas(img)
            SetCanvasSlot(islot, mx, iconY, iconDim, iconDim, 0.5, 0.5, zBase + 2)
        end
    end

    return fillBox
end

local function RenderBorderOutline(outer, canvas, cx, cy, w, h, thickness, col, zOrder)
    local t = thickness or 2.0
    local halfW = w * 0.5
    local halfH = h * 0.5
    AddBorderFast(outer, canvas, cx, cy - halfH, w, t, col, zOrder)
    AddBorderFast(outer, canvas, cx, cy + halfH, w, t, col, zOrder)
    AddBorderFast(outer, canvas, cx - halfW, cy, t, h, col, zOrder)
    AddBorderFast(outer, canvas, cx + halfW, cy, t, h, col, zOrder)
end

UpdateStatusBanner = function(textOverride)
    if not MapUI or not Core.IsValidObj(MapUI.StatusText) then return end
    local msg = textOverride
    if not msg then
        if InteractionMode == "Place" and Core.IsValidObj(PendingBuildable) then
            local bName = "Machine"
            pcall(function() bName = PendingBuildable.DisplayName:ToString() end)
            msg = string.format("BUILD: %s (Rot %d°) | Click: Place Ghost | R: Rotate | Right-Click: Cancel", bName, PendingRotationDeg)
        elseif InteractionMode == "Paste" then
            msg = string.format("PASTE (%d machine(s), Rot %d°) | Click: Stamp Ghosts | R: Rotate | Right-Click: Cancel", #Clipboard, PendingRotationDeg)
        else
            local selCount = 0
            for _ in pairs(SelectedMachines) do selCount = selCount + 1 end
            msg = string.format("Floor %d/%d | Selected: %d | B: Build | Drag/Shift+Click: Select | Ctrl+C: Copy | Click Icon: Toggle | Scroll: Zoom",
                SelectedFloorIdx, math.max(1, #CurrentFloors), selCount)
        end
    end
    pcall(function() MapUI.StatusText:SetText(Core.MakeText(msg)) end)
end

UpdateActionBar = function()
    if not MapUI then return end
    local pendingN = #PendingGhosts
    if Core.IsValidObj(MapUI.ApplyBtnText) then
        pcall(function()
            if pendingN > 0 then
                MapUI.ApplyBtnText:SetText(Core.MakeText(string.format("Apply Changes (%d)", pendingN)))
            else
                MapUI.ApplyBtnText:SetText(Core.MakeText("Apply Changes"))
            end
        end)
    end
    if Core.IsValidObj(MapUI.DiscardBtn) then
        pcall(function()
            MapUI.DiscardBtn:SetVisibility(pendingN > 0 and 0 or 2) -- Visible vs Collapsed
        end)
    end
end

local function FitViewTransformToFloor()
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor or #floor.platforms == 0 then return end

    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        if b.cx - b.ex < minX then minX = b.cx - b.ex end
        if b.cx + b.ex > maxX then maxX = b.cx + b.ex end
        if b.cy - b.ey < minY then minY = b.cy - b.ey end
        if b.cy + b.ey > maxY then maxY = b.cy + b.ey end
    end

    local cx, cy = (minX + maxX) * 0.5, (minY + maxY) * 0.5
    if floor.machines and #floor.machines > 0 then
        local xs, ys = {}, {}
        for _, me in ipairs(floor.machines) do
            table.insert(xs, me.x)
            table.insert(ys, me.y)
            if me.x - 300.0 < minX then minX = me.x - 300.0 end
            if me.x + 300.0 > maxX then maxX = me.x + 300.0 end
            if me.y - 300.0 < minY then minY = me.y - 300.0 end
            if me.y + 300.0 > maxY then maxY = me.y + 300.0 end
        end
        table.sort(xs)
        table.sort(ys)
        cx = xs[math.ceil(#xs * 0.5)]
        cy = ys[math.ceil(#ys * 0.5)]
    end

    local spanX = math.max(1200.0, maxX - minX)
    local spanY = math.max(1200.0, maxY - minY)
    local pad = 90.0
    local availW = math.max(300.0, ViewTransform.canvasW - pad)
    local availH = math.max(300.0, ViewTransform.canvasH - pad)

    -- Default base scale makes 1x1 cells larger (~28px) for comfortable inspection while still fitting smaller floors
    local fitted = math.min(availW / spanX, availH / spanY)
    ViewTransform.cx = cx
    ViewTransform.cy = cy
    ViewTransform.scale = Core.Clamp(math.max(fitted, 0.28), 0.14, 0.90)
    ViewTransform.floorZ = floor.z
    ViewTransform.hasFitted = true
end

local function MeasureMapCanvasSize()
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return false end
    local slateLib = Core.GetCDO(PATHS.SlateLibCDO)
    local layoutLib = Core.GetCDO(PATHS.WidgetLayoutLibCDO)
    local pc = Core.GetLocalPlayerController()

    if Core.IsValidObj(slateLib) and slateLib.GetLocalSize then
        for _, wgt in ipairs({ MapUI.MapCanvas, MapUI.MapBg }) do
            if Core.IsValidObj(wgt) and wgt.GetCachedGeometry then
                local ok, sz = pcall(function() return slateLib:GetLocalSize(wgt:GetCachedGeometry()) end)
                if ok and sz then
                    local w, h = tonumber(sz.X), tonumber(sz.Y)
                    if IsFiniteNum(w) and IsFiniteNum(h) and w > 120.0 and h > 120.0 then
                        local changed = (math.abs(w - ViewTransform.canvasW) > 4.0 or math.abs(h - ViewTransform.canvasH) > 4.0)
                        ViewTransform.canvasW = w
                        ViewTransform.canvasH = h
                        return changed
                    end
                end
            end
        end
    end

    if Core.IsValidObj(layoutLib) and Core.IsValidObj(pc) and layoutLib.GetViewportSize then
        local okV, rawVp = pcall(function() return layoutLib:GetViewportSize(pc) end)
        local vpScale = 1.0
        pcall(function()
            if layoutLib.GetViewportScale then
                local s = tonumber(layoutLib:GetViewportScale(pc))
                if IsFiniteNum(s) and s > 0.05 then vpScale = s end
            end
        end)
        if okV and rawVp and IsFiniteNum(tonumber(rawVp.X)) and IsFiniteNum(tonumber(rawVp.Y)) and rawVp.X > 100 then
            local umgW = rawVp.X / vpScale
            local umgH = rawVp.Y / vpScale
            local w = umgW * 0.88 - 170.0
            local h = umgH * 0.90 - 76.0
            if w > 120.0 and h > 120.0 then
                local changed = (math.abs(w - ViewTransform.canvasW) > 4.0 or math.abs(h - ViewTransform.canvasH) > 4.0)
                ViewTransform.canvasW = w
                ViewTransform.canvasH = h
                return changed
            end
        end
    end
    return false
end

RefreshDynamicOverlay = function()
    if not MapUI or not Core.IsValidObj(MapUI.OverlayCanvas) then return end
    ClearCanvasChildren(MapUI.OverlayCanvas)

    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = Core.GetLocalPlayerController()
    local cellPx = CELL_CM * ViewTransform.scale

    -- 1. Box-select live marquee
    if MouseState.lDraggingBox and MouseState.lastCursorMx and MouseState.lastCursorMy then
        local x1 = math.min(MouseState.lStartX, MouseState.lastCursorMx)
        local x2 = math.max(MouseState.lStartX, MouseState.lastCursorMx)
        local y1 = math.min(MouseState.lStartY, MouseState.lastCursorMy)
        local y2 = math.max(MouseState.lStartY, MouseState.lastCursorMy)
        local bw = math.max(4.0, x2 - x1)
        local bh = math.max(4.0, y2 - y1)
        local bx = (x1 + x2) * 0.5
        local by = (y1 + y2) * 0.5

        local fill = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if Core.IsValidObj(fill) then
            pcall(function() fill:SetBrushColor(COLORS.BoxSelectFill) end)
            local fs = MapUI.OverlayCanvas:AddChildToCanvas(fill)
            SetCanvasSlot(fs, bx, by, bw, bh, 0.5, 0.5, 50)
        end
        RenderBorderOutline(outer, MapUI.OverlayCanvas, bx, by, bw, bh, 2.0, COLORS.BoxSelectLine, 51)
    end

    -- 2. Cursor ghost previews (Place mode or repeatable Factorio-style Paste mode)
    if (InteractionMode == "Place" or InteractionMode == "Paste")
        and MouseState.lastCursorMx and MouseState.lastCursorMy
        and MouseState.lastCursorMx >= 0 and MouseState.lastCursorMx <= ViewTransform.canvasW
        and MouseState.lastCursorMy >= 0 and MouseState.lastCursorMy <= ViewTransform.canvasH
    then
        local wx, wy = CanvasToWorld(MouseState.lastCursorMx, MouseState.lastCursorMy)
        local itemsToPreview = {}
        if InteractionMode == "Place" and Core.IsValidObj(PendingBuildable) then
            local cx, cy = StationData.GetMachineFootprintCells(nil, PendingBuildable)
            local clsKey = select(1, GetMachineClassKey(nil, PendingBuildable))
            local sprite = RequestMachineSprite(clsKey, nil, "Other", PendingBuildable)
            table.insert(itemsToPreview, {
                buildable = PendingBuildable,
                wx = wx, wy = wy,
                yaw = PendingRotationDeg,
                cellsX = cx, cellsY = cy,
                sprite = sprite,
            })
        elseif InteractionMode == "Paste" and #Clipboard > 0 then
            local rad = math.rad(PendingRotationDeg)
            local cosA, sinA = math.cos(rad), math.sin(rad)
            for _, item in ipairs(Clipboard) do
                local rdx = item.dx * cosA - item.dy * sinA
                local rdy = item.dx * sinA + item.dy * cosA
                table.insert(itemsToPreview, {
                    buildable = item.buildable,
                    wx = wx + rdx, wy = wy + rdy,
                    yaw = (item.yaw or 0.0) + PendingRotationDeg,
                    cellsX = item.cellsX or 1,
                    cellsY = item.cellsY or 1,
                    sprite = item.sprite,
                })
            end
        end

        for _, gp in ipairs(itemsToPreview) do
            local sx, sy = SnapWorldToMachineGrid(gp.wx, gp.wy, gp.cellsX, gp.cellsY, gp.yaw)
            local gmx, gmy = WorldToCanvas(sx, sy)
            local onMod = IsPointOverAnyFloorModule(sx, sy, floor)
            local inWall = IsFootprintBlockedByWall(sx, sy, gp.cellsX, gp.cellsY, gp.yaw, floor)
            local hasMat = PlayerHasBuildableMaterials(pc, gp.buildable, 1)
            local valid = onMod and (not inWall) and hasMat
            local rx, ry = GetRotatedCellDims(gp.cellsX, gp.cellsY, gp.yaw)
            local pxW = rx * cellPx
            local pxH = ry * cellPx

            CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.OverlayCanvas, gmx, gmy, pxW, pxH, gp.yaw, "Other", gp.sprite, true, valid, 55, false)
            RenderBorderOutline(outer, MapUI.OverlayCanvas, gmx, gmy, pxW, pxH, 2.0, valid and COLORS.GhostBorderOk or COLORS.GhostBorderBad, 56)
        end
    end

    -- 3. Hover tooltips: unconnected item port or conveyor carried item
    local hoveredConv = nil
    local hoveredPort = nil
    if InteractionMode == "Select" and not MouseState.lDraggingBox and not MouseState.rPanning
        and MouseState.lastCursorMx and MouseState.lastCursorMy
        and MouseState.lastCursorMx >= 0 and MouseState.lastCursorMx <= ViewTransform.canvasW
        and MouseState.lastCursorMy >= 0 and MouseState.lastCursorMy <= ViewTransform.canvasH
    then
        local wx, wy = CanvasToWorld(MouseState.lastCursorMx, MouseState.lastCursorMy)
        for _, rp in ipairs(RenderedPorts) do
            if math.abs(wx - rp.x) <= rp.halfW and math.abs(wy - rp.y) <= rp.halfH then
                hoveredPort = rp
                break
            end
        end
        if hoveredPort then
            local portLabel = "Item Port"
            if hoveredPort.isInput and not hoveredPort.isOutput then
                portLabel = "Item Port (Input)"
            elseif hoveredPort.isOutput and not hoveredPort.isInput then
                portLabel = "Item Port (Output)"
            elseif hoveredPort.isInput and hoveredPort.isOutput then
                portLabel = "Item Port (Input / Output)"
            end
            local tipBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
            local tipTxt = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, pc)
            if Core.IsValidObj(tipBorder) and Core.IsValidObj(tipTxt) then
                pcall(function()
                    tipBorder:SetBrushColor(COLORS.TooltipBg)
                    tipBorder:SetPadding({ Left = 8.0, Top = 5.0, Right = 8.0, Bottom = 5.0 })
                    tipTxt:SetSize(12)
                    tipTxt:SetText(Core.MakeText(portLabel))
                    tipBorder:AddChild(tipTxt)
                end)
                local tx = Core.Clamp(MouseState.lastCursorMx + 18.0, 90.0, ViewTransform.canvasW - 110.0)
                local ty = Core.Clamp(MouseState.lastCursorMy - 24.0, 24.0, ViewTransform.canvasH - 24.0)
                local tSlot = MapUI.OverlayCanvas:AddChildToCanvas(tipBorder)
                SetCanvasSlot(tSlot, tx, ty, 195.0, 28.0, 0.0, 1.0, 80)
            end
        else
            for _, cm in ipairs(RenderedConveyors) do
                if math.abs(wx - cm.x) <= cm.halfW and math.abs(wy - cm.y) <= cm.halfH then
                    hoveredConv = cm
                    break
                end
            end
            if hoveredConv then
                local item = StationData.GetPrimaryItemForMachine(hoveredConv.machine)
                if Core.IsValidObj(item) then
                    local itemName = "Item"
                    pcall(function()
                        if item.DisplayName then itemName = item.DisplayName:ToString()
                        elseif item.Name then itemName = item.Name:ToString()
                        else itemName = SafeFNameStr(item) or "Item" end
                    end)

                    local tipBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
                    local tipHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
                    local tipIcon = Core.CreateUserWidget(PATHS.WBPItemClass, MapUI.Window, pc)
                    local tipTxt = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, pc)
                    if Core.IsValidObj(tipBorder) and Core.IsValidObj(tipHBox) and Core.IsValidObj(tipIcon) and Core.IsValidObj(tipTxt) then
                        pcall(function()
                            tipBorder:SetBrushColor(COLORS.TooltipBg)
                            tipBorder:SetPadding({ Left = 6.0, Top = 4.0, Right = 8.0, Bottom = 4.0 })
                            tipIcon:SetIconSize(22.0)
                            tipIcon:SetItem(item)
                            tipTxt:SetSize(12)
                            tipTxt:SetText(Core.MakeText(itemName))
                            local iSlot = tipHBox:AddChildToHorizontalBox(tipIcon)
                            if Core.IsValidObj(iSlot) then
                                iSlot:SetVerticalAlignment(2)
                                iSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 6.0, Bottom = 0.0 })
                            end
                            local tSlot = tipHBox:AddChildToHorizontalBox(tipTxt)
                            if Core.IsValidObj(tSlot) then tSlot:SetVerticalAlignment(2) end
                            tipBorder:AddChild(tipHBox)
                        end)
                        local tx = Core.Clamp(MouseState.lastCursorMx + 18.0, 90.0, ViewTransform.canvasW - 100.0)
                        local ty = Core.Clamp(MouseState.lastCursorMy - 24.0, 24.0, ViewTransform.canvasH - 24.0)
                        local tSlot = MapUI.OverlayCanvas:AddChildToCanvas(tipBorder)
                        SetCanvasSlot(tSlot, tx, ty, 190.0, 32.0, 0.0, 1.0, 80)
                    end
                end
            end
        end
    end

    LastHoveredPortIdx = hoveredPort and hoveredPort.idx or nil
    LastHoveredConvAddr = hoveredConv and hoveredConv.addr or nil
    LastHadDynamicOverlay = (MouseState.lDraggingBox or InteractionMode ~= "Select" or hoveredConv ~= nil or hoveredPort ~= nil)
end

local function RefreshSelectionLayer()
    if not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) then return end
    ClearCanvasChildren(MapUI.SelectionCanvas)

    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = MapUI.PC

    for _, rm in ipairs(RenderedMachines) do
        if SelectedMachines[rm.addr] ~= nil then
            local bx, by = WorldToBaseCanvas(rm.x, rm.y)
            local rx, ry = GetRotatedCellDims(rm.cellsX or 1, rm.cellsY or 1, rm.yaw or 0)
            local pxW = math.max(8.0, rx * BASE_CELL_PX)
            local pxH = math.max(8.0, ry * BASE_CELL_PX)
            local selFill = Core.CreateRawWidget(PATHS.BorderClass, outer)
            if Core.IsValidObj(selFill) then
                pcall(function()
                    selFill:SetVisibility(3)
                    selFill:SetBrushColor(COLORS.SelectedFill)
                end)
                local ss = MapUI.SelectionCanvas:AddChildToCanvas(selFill)
                SetCanvasSlot(ss, bx, by, pxW, pxH, 0.5, 0.5, 1)
            end
            RenderBorderOutline(outer, MapUI.SelectionCanvas, bx, by, pxW, pxH, 2.5, COLORS.Selected, 2)
        end
    end

    for _, gp in ipairs(PendingGhosts) do
        if math.abs((gp.z or floor.z) - floor.z) <= 250.0 then
            local gbx, gby = WorldToBaseCanvas(gp.x, gp.y)
            local rx, ry = GetRotatedCellDims(gp.cellsX or 1, gp.cellsY or 1, gp.yaw or 0)
            local pxW = math.max(8.0, rx * BASE_CELL_PX)
            local pxH = math.max(8.0, ry * BASE_CELL_PX)
            local sprite = gp.actorClsPath and RequestMachineSprite(gp.actorClsPath, nil, "Other", gp.buildable) or gp.sprite
            CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.SelectionCanvas, gbx, gby, pxW, pxH, gp.yaw or 0, "Other", sprite, true, true, 5, false)
            RenderBorderOutline(outer, MapUI.SelectionCanvas, gbx, gby, pxW, pxH, 2.0, COLORS.GhostBorderOk, 6)
        end
    end

    UpdateActionBar()
    UpdateStatusBanner()
end

RefreshStationMapCanvas = function()
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return end

    MeasureMapCanvasSize()
    if not ViewTransform.hasFitted then
        FitViewTransformToFloor()
    end

    ClearCanvasChildren(MapUI.MapCanvas)
    ClearCanvasChildren(MapUI.SelectionCanvas)
    ClearCanvasChildren(MapUI.IconCanvas)
    RenderedMachines = {}
    RenderedConveyors = {}
    RenderedPorts = {}
    RenderedGridLines = {}
    LastGridTier = nil
    LastGridZoomRatio = nil
    FloorIconButtons = {}

    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor or #floor.platforms == 0 then
        ApplyViewTransform()
        UpdateStatusBanner("No station modules on this floor")
        RefreshDynamicOverlay()
        return
    end

    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = MapUI.PC
    local cellPx = BASE_CELL_PX

    -- Compute generous world bounds covering ALL station modules AND all floor machines so grid never cuts off
    local bMinX, bMaxX, bMinY, bMaxY = math.huge, -math.huge, math.huge, -math.huge
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        if b.cx - b.ex < bMinX then bMinX = b.cx - b.ex end
        if b.cx + b.ex > bMaxX then bMaxX = b.cx + b.ex end
        if b.cy - b.ey < bMinY then bMinY = b.cy - b.ey end
        if b.cy + b.ey > bMaxY then bMaxY = b.cy + b.ey end
    end
    if floor.machines then
        for _, me in ipairs(floor.machines) do
            if me.x - 400.0 < bMinX then bMinX = me.x - 400.0 end
            if me.x + 400.0 > bMaxX then bMaxX = me.x + 400.0 end
            if me.y - 400.0 < bMinY then bMinY = me.y - 400.0 end
            if me.y + 400.0 > bMaxY then bMaxY = me.y + 400.0 end
        end
    end
    local padCm = 400.0
    local minCol = math.floor((bMinX - padCm - ViewTransform.gridOriginX) / CELL_CM)
    local maxCol = math.ceil((bMaxX + padCm - ViewTransform.gridOriginX) / CELL_CM)
    local minRow = math.floor((bMinY - padCm - ViewTransform.gridOriginY) / CELL_CM)
    local maxRow = math.ceil((bMaxY + padCm - ViewTransform.gridOriginY) / CELL_CM)
    -- Expand narrow axis symmetrically so tall or wide stations still show a balanced square field
    if (maxCol - minCol) < 48 then
        local extra = math.ceil((48 - (maxCol - minCol)) * 0.5)
        minCol = minCol - extra
        maxCol = maxCol + extra
    end
    if (maxRow - minRow) < 40 then
        local extra = math.ceil((40 - (maxRow - minRow)) * 0.5)
        minRow = minRow - extra
        maxRow = maxRow + extra
    end
    -- Align grid range to multiples of 8 so 4x4 and 8x8 zoom-out squares stay symmetrical
    minCol = math.floor(minCol / 8) * 8
    maxCol = math.ceil(maxCol / 8) * 8
    minRow = math.floor(minRow / 8) * 8
    maxRow = math.ceil(maxRow / 8) * 8

    local totalCols = maxCol - minCol
    local totalRows = maxRow - minRow
    local maxDim = math.max(totalCols, totalRows)
    local stepCells = 1
    if maxDim > 480 then
        stepCells = 4
    elseif maxDim > 240 then
        stepCells = 2
    end

    local gridMinX = ViewTransform.gridOriginX + minCol * CELL_CM
    local gridMaxX = ViewTransform.gridOriginX + maxCol * CELL_CM
    local gridMinY = ViewTransform.gridOriginY + minRow * CELL_CM
    local gridMaxY = ViewTransform.gridOriginY + maxRow * CELL_CM

    local bGridMinX, bGridMinY = WorldToBaseCanvas(gridMinX, gridMinY)
    local bGridMaxX, bGridMaxY = WorldToBaseCanvas(gridMaxX, gridMaxY)
    local gridSpanW = math.max(100.0, bGridMaxX - bGridMinX)
    local gridSpanH = math.max(100.0, bGridMaxY - bGridMinY)
    local gridMidX = (bGridMinX + bGridMaxX) * 0.5
    local gridMidY = (bGridMinY + bGridMaxY) * 0.5

    local function addGridAxisLines(startIdx, endIdx, isVertical, spanOther, midOther)
        local maxLines = 260
        local drawn = 0
        local originAxis = isVertical and ViewTransform.gridOriginX or ViewTransform.gridOriginY
        for idx = startIdx, endIdx, stepCells do
            drawn = drawn + 1
            if drawn > maxLines then break end
            local wPos = originAxis + idx * CELL_CM
            local bx, by = WorldToBaseCanvas(isVertical and wPos or 0.0, isVertical and 0.0 or wPos)
            local posX = isVertical and bx or midOther
            local posY = isVertical and midOther or by
            local isMajor4 = ((idx % 4) == 0)
            local isMajor8 = ((idx % 8) == 0)
            local initThick = isMajor4 and 2.2 or 1.4
            local line, s = AddBorderFast(
                outer, MapUI.MapCanvas, posX, posY,
                isVertical and initThick or spanOther,
                isVertical and spanOther or initThick,
                isMajor4 and COLORS.GridMajor or COLORS.GridLine, 3
            )
            if line and s then
                table.insert(RenderedGridLines, {
                    border = line,
                    slot = s,
                    isVertical = isVertical,
                    spanOther = spanOther,
                    isMajor4 = isMajor4,
                    isMajor8 = isMajor8,
                })
            end
        end
    end

    -- 1. Full static square cell grid lines (Z=3, above ModuleFill so grid is visible across module tiles)
    addGridAxisLines(minCol, maxCol, true, gridSpanH, gridMidY)
    addGridAxisLines(minRow, maxRow, false, gridSpanW, gridMidX)
    UpdateGridAppearanceForZoom(ViewTransform.scale / BASE_PX_PER_CM)

    -- 2. Render station modules (interior fill + crisp 4-edge module borders)
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        local mx, my = WorldToBaseCanvas(b.cx, b.cy)
        local mw = math.max(12.0, b.ex * 2.0 * BASE_PX_PER_CM)
        local mh = math.max(12.0, b.ey * 2.0 * BASE_PX_PER_CM)

        AddBorderFast(outer, MapUI.MapCanvas, mx, my, mw, mh, COLORS.ModuleFill, 2)
        RenderBorderOutline(outer, MapUI.MapCanvas, mx, my, mw, mh, 5.5, COLORS.ModuleBorder, 4)
    end

    -- 2b. Queue structural module walls for fast chunked 2-pass continuous rendering (Z=5 border, Z=6 opaque fill)
    CanvasRenderGen = CanvasRenderGen + 1
    local myRenderGen = CanvasRenderGen
    local deferredWalls = {}
    if floor.walls and #floor.walls > 0 then
        for _, w in ipairs(floor.walls) do
            local wx, wy = WorldToBaseCanvas(w.cx, w.cy)
            local ww = math.max(6.0, (w.maxX - w.minX) * BASE_PX_PER_CM)
            local wh = math.max(6.0, (w.maxY - w.minY) * BASE_PX_PER_CM)
            table.insert(deferredWalls, { wx = wx, wy = wy, ww = ww, wh = wh })
        end
    end

    local deferredConveyors = {}
    local deferredPorts = {}

    -- 3. Collect & render placed machines on this floor once at BASE_CELL_PX (station-local coords only)
    local floorMachines = floor.machines or {}

    local presentAddrs = {}
    for _, me in ipairs(floorMachines) do
        if Core.IsValidObj(me.machine) then
            presentAddrs[me.machine:GetAddress()] = true
        end
    end
    local seenUndergroundPairs = {}

    for _, me in ipairs(floorMachines) do
        local m = me.machine
        if Core.IsValidObj(m) and not StationData.ShouldHideMachineOnMap(m) then
            local mwx, mwy, mwz, myaw = me.x, me.y, me.z, me.yaw
            local mx, my = WorldToBaseCanvas(mwx, mwy)
            local cat = StationData.GetMachineCategory(m)
            local cellsX, cellsY = StationData.GetMachineFootprintCells(m)
            local rx, ry = GetRotatedCellDims(cellsX, cellsY, myaw)
            local pxW = math.max(8.0, rx * cellPx)
            local pxH = math.max(8.0, ry * cellPx)
            local okB, bldRaw = pcall(function() return m.Buildable end)
            local bld = okB and Core.IsValidObj(bldRaw) and bldRaw or nil
            local okR, rec = pcall(function() return m.Recipe end)
            local clsKey = select(1, GetMachineClassKey(m, bld))
            local sprite = RequestMachineSprite(clsKey, m, cat, bld)
            local mAddr = m:GetAddress()

            local overlayChips = {}
            local isContainer = (cat == "Container")
            local isProducer = false
            if isContainer then
                local topItems = StationData.GetContainerTopItems(m, (pxW >= 72.0) and 2 or 1)
                for _, entry in ipairs(topItems) do
                    table.insert(overlayChips, { item = entry.Item, rate = nil })
                end
            elseif cat ~= "Conveyor" then
                local outputs = StationData.GetProducerOutputsAndRates(m)
                if #outputs > 0 then
                    isProducer = true
                    local maxChips = (pxW >= 80.0) and 2 or 1
                    for i = 1, math.min(maxChips, #outputs) do
                        table.insert(overlayChips, { item = outputs[i].Item, rate = outputs[i].Rate })
                    end
                end
            end
            local hasBottomOverlay = (#overlayChips > 0)

            local recEntry = {
                machine = m,
                addr = mAddr,
                x = mwx,
                y = mwy,
                z = mwz,
                yaw = myaw,
                cellsX = cellsX,
                cellsY = cellsY,
                halfW = rx * CELL_CM * 0.5,
                halfH = ry * CELL_CM * 0.5,
                cat = cat,
                buildable = bld,
                recipe = okR and rec or nil,
                actorClsPath = clsKey,
                sprite = sprite,
                displayName = StationData.GetMachineDisplayName(m),
            }
            table.insert(RenderedMachines, recEntry)
            if cat == "Conveyor" then
                table.insert(RenderedConveyors, recEntry)
                table.insert(deferredConveyors, { x = mwx, y = mwy, mx = mx, my = my, pxW = pxW, pxH = pxH, myaw = myaw, sprite = sprite })
            else
                CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.MapCanvas, mx, my, pxW, pxH, myaw, cat, sprite, false, true, 10, hasBottomOverlay)
            end

            -- Underground belt enhancements: direction arrow on tile + dashed pair line + second endpoint tile
            local clsLow = clsKey and clsKey:lower() or ""
            local uInfo = (clsLow:find("underground", 1, true) ~= nil) and StationData.GetUndergroundBeltPairInfo(m, CurrentFrameXform) or nil
            if uInfo then
                local arrowCol = GetTierArrowColor(sprite and sprite.tier or 1)
                RenderDirectionChevron(outer, MapUI.MapCanvas, mx, my, math.min(pxW, pxH) * 0.60, myaw, arrowCol, 15)
                if uInfo.pairX and uInfo.pairY then
                    local omx, omy = WorldToBaseCanvas(uInfo.pairX, uInfo.pairY)
                    local pKey = (uInfo.pairAddr and (mAddr < uInfo.pairAddr and (mAddr .. ":" .. uInfo.pairAddr) or (uInfo.pairAddr .. ":" .. mAddr))) or mAddr
                    if not seenUndergroundPairs[pKey] then
                        seenUndergroundPairs[pKey] = true
                        local lineCol = { R = arrowCol.R, G = arrowCol.G, B = arrowCol.B, A = 0.80 }
                        local x1, y1, x2, y2 = mx, my, omx, omy
                        if uInfo.isInput == false then
                            x1, y1, x2, y2 = omx, omy, mx, my
                        end
                        RenderDashedLine(outer, MapUI.MapCanvas, x1, y1, x2, y2, lineCol, 2.6, 10.0, 6.0, 17)
                        local linkAng = math.deg(math.atan(y2 - y1, x2 - x1))
                        RenderDirectionChevron(outer, MapUI.MapCanvas, (x1 + x2) * 0.5, (y1 + y2) * 0.5, 18.0, linkAng, arrowCol, 18)
                    end
                    -- Render second endpoint tile if the paired end wasn't already listed as a separate simulation object
                    if not (uInfo.pairAddr and presentAddrs[uInfo.pairAddr]) then
                        CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.MapCanvas, omx, omy, pxW, pxH, myaw, cat, sprite, false, true, 10, false)
                        RenderDirectionChevron(outer, MapUI.MapCanvas, omx, omy, math.min(pxW, pxH) * 0.60, myaw, arrowCol, 15)
                    end
                end
            end

            if hasBottomOverlay then
                local isHidden = StationData.IsMachineIconHidden(m)
                local iconSize = Core.Clamp(math.min(pxW * (#overlayChips > 1 and 0.34 or 0.50), pxH * 0.36), 16.0, 32.0)
                local badgeW = #overlayChips * (iconSize + 10.0) + ((#overlayChips > 1) and 4.0 or 0.0)
                if isProducer then
                    badgeW = math.max(badgeW, #overlayChips * math.max(44.0, iconSize + 20.0))
                end
                local badgeH = isProducer and (iconSize + 18.0) or (iconSize + 6.0)
                local badgeY = (pxH >= 52.0) and (my + pxH * 0.24) or my

                local ov = Core.CreateRawWidget(PATHS.OverlayClass, outer)
                local iconBtn = Core.CreateUserWidget(PATHS.WBPButtonClass, MapUI.Window, pc)
                local chipsHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
                if Core.IsValidObj(ov) and Core.IsValidObj(iconBtn) and Core.IsValidObj(chipsHBox) then
                    pcall(function()
                        iconBtn:SetBackgroundColour({ R = 0.03, G = 0.04, B = 0.06, A = 0.72 })
                        iconBtn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                        local bSlot = ov:AddChildToOverlay(iconBtn)
                        if Core.IsValidObj(bSlot) then
                            bSlot:SetHorizontalAlignment(0)
                            bSlot:SetVerticalAlignment(0)
                        end
                        local cSlot = ov:AddChildToOverlay(chipsHBox)
                        if Core.IsValidObj(cSlot) then
                            cSlot:SetHorizontalAlignment(2)
                            cSlot:SetVerticalAlignment(2)
                        end
                        chipsHBox:SetVisibility(3)

                        for ci, chip in ipairs(overlayChips) do
                            local chipVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
                            local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, MapUI.Window, pc)
                            if Core.IsValidObj(chipVBox) and Core.IsValidObj(itemW) then
                                chipVBox:SetVisibility(3)
                                local iwSlot = chipVBox:AddChildToVerticalBox(itemW)
                                if Core.IsValidObj(iwSlot) then iwSlot:SetHorizontalAlignment(2) end
                                itemW.TooltipEnabled = false
                                itemW:SetVisibility(3)
                                itemW:SetIconSize(iconSize)
                                itemW:SetItem(chip.item)
                                itemW:SetColorAndOpacity({ R = 1.0, G = 1.0, B = 1.0, A = isHidden and 0.25 or 1.0 })

                                if chip.rate ~= nil then
                                    local rTxt = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, pc)
                                    if Core.IsValidObj(rTxt) then
                                        local rtSlot = chipVBox:AddChildToVerticalBox(rTxt)
                                        if Core.IsValidObj(rtSlot) then rtSlot:SetHorizontalAlignment(2) end
                                        local rateStr = (chip.rate >= 10.0) and string.format("%.0f/min", chip.rate) or string.format("%.1f/min", chip.rate)
                                        rTxt:SetVisibility(3)
                                        rTxt:SetSize(10)
                                        rTxt:SetText(Core.MakeText(rateStr))
                                    end
                                end

                                local hbSlot = chipsHBox:AddChildToHorizontalBox(chipVBox)
                                if Core.IsValidObj(hbSlot) then
                                    hbSlot:SetVerticalAlignment(2)
                                    if ci > 1 then
                                        hbSlot:SetPadding({ Left = 4.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                                    end
                                end
                            end
                        end
                    end)

                    local iconTarget = Core.IsValidObj(MapUI.IconCanvas) and MapUI.IconCanvas or MapUI.MapCanvas
                    local iSlot = iconTarget:AddChildToCanvas(ov)
                    SetCanvasSlot(iSlot, mx, badgeY, badgeW, badgeH, 0.5, 0.5, 40)

                    FloorIconButtons[mAddr] = { btn = iconBtn, widget = chipsHBox }
                    local capturedM = m
                    local capturedGroup = chipsHBox
                    Core.RegisterWBPButtonClick(iconBtn, function()
                        local nowHidden = StationData.ToggleMachineIcon(capturedM)
                        if Core.IsValidObj(capturedGroup) then
                            pcall(function()
                                capturedGroup:SetRenderOpacity(nowHidden and 0.25 or 1.0)
                            end)
                        end
                    end)
                end
            end
        end
    end

    -- 3b. Collect ALL machine item ports (2/3 inside machine, 1/3 outside, always displayed even when overlapping belts/objects)
    local portBadgeBasePx = math.max(14.0, BASE_CELL_PX * 0.58)
    local portHalfCm = 32.0
    local portsByKey = {}
    for _, rm in ipairs(RenderedMachines) do
        local cn = (rm.actorClsPath or ""):lower()
        local isTransportOnly = (rm.cat == "Conveyor")
            or cn:find("splitter", 1, true) or cn:find("balancer", 1, true)
            or cn:find("merger", 1, true) or cn:find("underground", 1, true)
        if not isTransportOnly and Core.IsValidObj(rm.machine) then
            local ports = StationData.GetMachineItemPorts(rm.machine, rm.x, rm.y, rm.yaw, rm.cellsX, rm.cellsY, CurrentFrameXform)
            for _, p in ipairs(ports) do
                local cellKey = string.format("%.0f,%.0f", p.px / 25.0, p.py / 25.0)
                local existing = portsByKey[cellKey]
                if not existing then
                    existing = {
                        x = p.px,
                        y = p.py,
                        isInput = p.isInput == true,
                        isOutput = p.isOutput == true,
                        machineName = rm.displayName,
                    }
                    portsByKey[cellKey] = existing
                else
                    if p.isInput then existing.isInput = true end
                    if p.isOutput then existing.isOutput = true end
                end
            end
        end
    end
    for _, pe in pairs(portsByKey) do
        local pmx, pmy = WorldToBaseCanvas(pe.x, pe.y)
        table.insert(deferredPorts, { pmx = pmx, pmy = pmy })
        table.insert(RenderedPorts, {
            idx = #RenderedPorts + 1,
            x = pe.x,
            y = pe.y,
            halfW = portHalfCm,
            halfH = portHalfCm,
            isInput = pe.isInput,
            isOutput = pe.isOutput,
            machineName = pe.machineName,
        })
    end

    -- Stream deferred walls, conveyor tiles, and port badges progressively across frames to avoid initial-open freezes
    if #deferredWalls > 0 or #deferredConveyors > 0 or #deferredPorts > 0 then
        local wIdx = 1
        local cIdx = 1
        local pIdx = 1
        local WALLS_PER_FRAME = 32
        local CONV_PER_FRAME = 24
        local PORTS_PER_FRAME = 12
        local wallBorderPad = 11.0
        local function pumpDeferredBatch()
            if myRenderGen ~= CanvasRenderGen or not Core.IsValidObj(ActiveMapWin) or not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then
                return
            end
            local wEnd = math.min(#deferredWalls, wIdx + WALLS_PER_FRAME - 1)
            while wIdx <= wEnd do
                local dw = deferredWalls[wIdx]
                AddBorderFast(outer, MapUI.MapCanvas, dw.wx, dw.wy, dw.ww + wallBorderPad, dw.wh + wallBorderPad, COLORS.WallBorder, 5)
                AddBorderFast(outer, MapUI.MapCanvas, dw.wx, dw.wy, dw.ww + 1.0, dw.wh + 1.0, COLORS.WallFill, 6)
                wIdx = wIdx + 1
            end
            local cEnd = math.min(#deferredConveyors, cIdx + CONV_PER_FRAME - 1)
            while cIdx <= cEnd do
                local dc = deferredConveyors[cIdx]
                CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.MapCanvas, dc.mx, dc.my, dc.pxW, dc.pxH, dc.myaw, "Conveyor", dc.sprite, false, true, 10, false)
                cIdx = cIdx + 1
            end
            local pEnd = math.min(#deferredPorts, pIdx + PORTS_PER_FRAME - 1)
            while pIdx <= pEnd do
                local dp = deferredPorts[pIdx]
                RenderUnconnectedItemPort(outer, MapUI.MapCanvas, dp.pmx, dp.pmy, portBadgeBasePx, 22)
                pIdx = pIdx + 1
            end
            if wIdx <= #deferredWalls or cIdx <= #deferredConveyors or pIdx <= #deferredPorts then
                ExecuteInGameThreadAfterFrames(1, pumpDeferredBatch)
            end
        end
        ExecuteInGameThreadAfterFrames(1, pumpDeferredBatch)
    end

    -- 4. Render player markers & nametags on this floor (converted into station-local space)
    local allPlayers = StationData.GetAllPlayersInfo(pc)
    for _, p in ipairs(allPlayers) do
        if p.HasPos then
            local plx, ply, plz = StationData.WorldToStationLocal(CurrentFrameXform, p.X, p.Y, p.Z, nil, nil, nil)
            if math.abs(plz - floor.z) <= 220.0 then
                local pmx, pmy = WorldToBaseCanvas(plx, ply)
                local pDot = Core.CreateRawWidget(PATHS.BorderClass, outer)
                if Core.IsValidObj(pDot) then
                    local col = p.IsLocal and COLORS.PlayerLocal or (p.IsOnline and COLORS.PlayerOnline or COLORS.PlayerOffline)
                    pcall(function()
                        pDot:SetVisibility(3)
                        pDot:SetBrushColor(col)
                    end)
                    local pSlot = MapUI.MapCanvas:AddChildToCanvas(pDot)
                    SetCanvasSlot(pSlot, pmx, pmy, 12.0, 12.0, 0.5, 0.5, 45)
                end
                local nameTxt = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, pc)
                if Core.IsValidObj(nameTxt) then
                    local nSlot = MapUI.MapCanvas:AddChildToCanvas(nameTxt)
                    SetCanvasSlot(nSlot, pmx, pmy - 16.0, 140.0, 20.0, 0.5, 1.0, 46)
                    pcall(function()
                        nameTxt:SetVisibility(3)
                        nameTxt:SetSize(11)
                        nameTxt:SetText(Core.MakeText(p.Name))
                    end)
                end
            end
        end
    end

    RefreshSelectionLayer()
    ApplyViewTransform()
    RefreshDynamicOverlay()
end

--------------------------------------------------------------------------------
-- Vertical Paginated Floor Selector (5 visible slots, ^ / v arrows)
--------------------------------------------------------------------------------

local function EnsureSelectedFloorVisibleInPage()
    local total = #CurrentFloors
    if total == 0 then FloorPageTopIdx = 1 return end
    local minTop = math.min(total, FLOOR_PAGE_SIZE)
    if not FloorPageTopIdx then
        FloorPageTopIdx = Core.Clamp(SelectedFloorIdx + math.floor(FLOOR_PAGE_SIZE / 2), minTop, total)
    end
    if SelectedFloorIdx > FloorPageTopIdx then
        FloorPageTopIdx = SelectedFloorIdx
    elseif SelectedFloorIdx <= FloorPageTopIdx - FLOOR_PAGE_SIZE then
        FloorPageTopIdx = SelectedFloorIdx + FLOOR_PAGE_SIZE - 1
    end
    FloorPageTopIdx = Core.Clamp(FloorPageTopIdx, minTop, total)
end

RebuildFloorButtons = function()
    if not MapUI or not Core.IsValidObj(MapUI.FloorSlotsBox) then return end
    FloorRailButtons = {}
    ClearCanvasChildren(MapUI.FloorSlotsBox)
    pcall(function() MapUI.FloorSlotsBox:ClearChildren() end)

    local total = #CurrentFloors
    if total == 0 then return end
    EnsureSelectedFloorVisibleInPage()

    local outer = Core.GetWidgetOuter(MapUI.Window)
    local topIdx = FloorPageTopIdx
    local botIdx = math.max(1, topIdx - FLOOR_PAGE_SIZE + 1)

    for flIdx = topIdx, botIdx, -1 do
        local thisIdx = flIdx
        local isSel = (thisIdx == SelectedFloorIdx)
        local bgCol = isSel and { R = 0.45, G = 0.28, B = 0.04, A = 0.96 } or COLORS.FloorNormal
        local txtCol = isSel and COLORS.FloorSelected or COLORS.PlayerLocal
        local btnWrap, btn = CreateLabeledButton(
            MapUI.Window, MapUI.PC, outer, tostring(thisIdx), 17, 96.0, 58.0, bgCol, txtCol,
            function()
                SelectedFloorIdx = thisIdx
                ViewTransform.hasFitted = false
                RebuildFloorButtons()
                RefreshStationMapCanvas()
            end,
            FloorRailButtons
        )
        if Core.IsValidObj(btnWrap) and Core.IsValidObj(btn) then
            pcall(function() btn:SetSelected(isSel) end)
            local slot = MapUI.FloorSlotsBox:AddChildToVerticalBox(btnWrap)
            if Core.IsValidObj(slot) then
                pcall(function()
                    slot:SetPadding({ Left = 4.0, Top = 4.0, Right = 4.0, Bottom = 4.0 })
                    slot:SetHorizontalAlignment(2)
                end)
            end
        end
    end

    if Core.IsValidObj(MapUI.FloorUpBtn) then
        pcall(function() MapUI.FloorUpBtn:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = (topIdx < total) and 1.0 or 0.35 }) end)
    end
    if Core.IsValidObj(MapUI.FloorDownBtn) then
        pcall(function() MapUI.FloorDownBtn:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = (botIdx > 1) and 1.0 or 0.35 }) end)
    end
end

--------------------------------------------------------------------------------
-- Selection, Ghost Placement, Copy-Paste & Apply Changes Actions
--------------------------------------------------------------------------------

local function CopySelectedMachines()
    Clipboard = {}
    local list = {}
    for _, entry in pairs(SelectedMachines) do
        if Core.IsValidObj(entry.machine) and Core.IsValidObj(entry.buildable) then
            table.insert(list, entry)
        end
    end
    if #list == 0 then
        UpdateStatusBanner("Select one or more machines first (click, Shift+click, or drag box)")
        return
    end

    -- Anchor clipboard offsets around snapped center so copied groups remain grid-aligned
    local cx, cy = 0.0, 0.0
    for _, e in ipairs(list) do
        cx = cx + e.x
        cy = cy + e.y
    end
    cx = cx / #list
    cy = cy / #list
    local anchorX = SnapAxisToCellGrid(cx, ViewTransform.gridOriginX, 1)
    local anchorY = SnapAxisToCellGrid(cy, ViewTransform.gridOriginY, 1)

    for _, e in ipairs(list) do
        local cellsX = e.cellsX or 1
        local cellsY = e.cellsY or 1
        table.insert(Clipboard, {
            buildable = e.buildable,
            dx = e.x - anchorX,
            dy = e.y - anchorY,
            yaw = e.yaw or 0.0,
            recipe = e.recipe,
            cellsX = cellsX,
            cellsY = cellsY,
            actorClsPath = e.actorClsPath,
            sprite = e.sprite,
            name = e.displayName,
        })
    end

    InteractionMode = "Paste"
    PendingRotationDeg = 0
    UpdateStatusBanner()
    RefreshDynamicOverlay()
end

local function CommitPendingGhosts()
    Core.Log(string.format("[StationMap] CommitPendingGhosts entered (inProgress=%s, pending=%d)", tostring(ApplyInProgress), #PendingGhosts))
    if ApplyInProgress then return end
    if #PendingGhosts == 0 then
        UpdateStatusBanner("No pending changes to apply")
        return
    end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local okMat, missingBld = CheckMaterialsForPendingList(pc, PendingGhosts)
    if not okMat then
        local mName = "machine"
        pcall(function() mName = missingBld.DisplayName:ToString() end)
        UpdateStatusBanner("Apply blocked: insufficient materials for " .. mName)
        return
    end

    ApplyInProgress = true
    local builtCount = 0
    local remaining = {}
    local lastErr = nil

    Core.Log(string.format("[StationMap] ApplyChanges starting for %d pending ghost(s)", #PendingGhosts))
    for _, g in ipairs(PendingGhosts) do
        local targetFloor = CurrentFloors[g.floorIdx] or CurrentFloors[SelectedFloorIdx]
        local plat, pb = FindPlatformAtWorldXY(g.x, g.y, targetFloor)
        local wx, wy, wz = StationData.StationLocalToWorld(CurrentFrameXform, g.x, g.y, g.z)
        local ok, err = IssueRemoteBuildMachine(pc, CurrentStation, plat, pb, g.buildable, g.x, g.y, g.z, wx, wy, wz, g.yaw, g.recipe)
        if ok then
            builtCount = builtCount + 1
        else
            lastErr = err
            table.insert(remaining, g)
        end
    end
    ApplyInProgress = false

    PendingGhosts = remaining
    UpdateActionBar()

    if builtCount > 0 then
        UpdateStatusBanner(string.format("Applied %d placement(s)%s", builtCount, (#remaining > 0 and (" (" .. #remaining .. " failed)") or "")))
        ExecuteInGameThreadWithDelay(300, function()
            StationData.InvalidateMachineCache()
            if Core.IsValidObj(CurrentStation) then
                local pc2 = Core.GetLocalPlayerController()
                local px2, py2, pz2 = nil, nil, nil
                if Core.IsValidObj(pc2) then
                    local pawn2 = pc2.Pawn
                    if Core.IsValidObj(pawn2) then
                        local okL, loc2 = pcall(function() return pawn2:K2_GetActorLocation() end)
                        if okL and loc2 and type(loc2.X) == "number" then
                            px2, py2, pz2 = loc2.X, loc2.Y or 0, loc2.Z or 0
                        end
                    end
                end
                local newFloors, _, _, gox2, goy2, xform2 = StationData.BuildStationFloorMap(CurrentStation, CurrentWalkFrame, px2, py2, pz2)
                if newFloors and #newFloors > 0 then
                    CurrentFloors = newFloors
                    CurrentFrameXform = xform2
                    if SelectedFloorIdx > #CurrentFloors then SelectedFloorIdx = #CurrentFloors end
                    ViewTransform.gridOriginX = gox2 or ViewTransform.gridOriginX
                    ViewTransform.gridOriginY = goy2 or ViewTransform.gridOriginY
                end
            end
            if IsMapOpen() then
                RefreshStationMapCanvas()
            end
        end)
    elseif lastErr then
        UpdateStatusBanner("Apply failed: " .. tostring(lastErr))
        RefreshSelectionLayer()
    end
end

local function HandleMapLeftClick(mx, my, isShift)
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local wx, wy = CanvasToWorld(mx, my)

    if InteractionMode == "Place" and Core.IsValidObj(PendingBuildable) then
        local cellsX, cellsY = StationData.GetMachineFootprintCells(nil, PendingBuildable)
        local sx, sy = SnapWorldToMachineGrid(wx, wy, cellsX, cellsY, PendingRotationDeg)
        local onMod = IsPointOverAnyFloorModule(sx, sy, floor)
        if not onMod then
            UpdateStatusBanner("Place inside a station module")
            return
        end
        if IsFootprintBlockedByWall(sx, sy, cellsX, cellsY, PendingRotationDeg, floor) then
            UpdateStatusBanner("Cannot place inside a module wall")
            return
        end
        local pc = Core.GetLocalPlayerController()
        if not PlayerHasBuildableMaterials(pc, PendingBuildable, 1) then
            UpdateStatusBanner("Insufficient materials in inventory")
            return
        end
        local clsKey = select(1, GetMachineClassKey(nil, PendingBuildable))
        table.insert(PendingGhosts, {
            buildable = PendingBuildable,
            floorIdx = SelectedFloorIdx,
            x = sx, y = sy, z = floor.z,
            yaw = PendingRotationDeg,
            cellsX = cellsX, cellsY = cellsY,
            actorClsPath = clsKey,
            sprite = clsKey and MachineSpriteCache[clsKey] or nil,
        })
        UpdateActionBar()
        RefreshSelectionLayer()
        return
    end

    if InteractionMode == "Paste" and #Clipboard > 0 then
        local pc = Core.GetLocalPlayerController()
        local rad = math.rad(PendingRotationDeg)
        local cosA, sinA = math.cos(rad), math.sin(rad)
        local staged = {}
        for _, item in ipairs(Clipboard) do
            if Core.IsValidObj(item.buildable) then
                local rdx = item.dx * cosA - item.dy * sinA
                local rdy = item.dx * sinA + item.dy * cosA
                local finalYaw = (item.yaw or 0.0) + PendingRotationDeg
                local sx, sy = SnapWorldToMachineGrid(wx + rdx, wy + rdy, item.cellsX or 1, item.cellsY or 1, finalYaw)
                if IsPointOverAnyFloorModule(sx, sy, floor) and not IsFootprintBlockedByWall(sx, sy, item.cellsX or 1, item.cellsY or 1, finalYaw, floor) then
                    table.insert(staged, {
                        buildable = item.buildable,
                        floorIdx = SelectedFloorIdx,
                        x = sx, y = sy, z = floor.z,
                        yaw = finalYaw,
                        cellsX = item.cellsX or 1,
                        cellsY = item.cellsY or 1,
                        actorClsPath = item.actorClsPath,
                        sprite = item.sprite,
                        recipe = item.recipe,
                    })
                end
            end
        end
        if #staged == 0 then
            UpdateStatusBanner("Paste inside a station module")
            return
        end
        local okMat = CheckMaterialsForPendingList(pc, staged)
        if not okMat then
            UpdateStatusBanner("Insufficient materials to paste group")
            return
        end
        for _, g in ipairs(staged) do
            table.insert(PendingGhosts, g)
        end
        UpdateActionBar()
        RefreshSelectionLayer()
        return
    end

    -- Select mode: find topmost machine under cursor (prefer non-conveyors or closest center)
    local hit = nil
    local bestDist = math.huge
    for _, rm in ipairs(RenderedMachines) do
        if math.abs(wx - rm.x) <= rm.halfW and math.abs(wy - rm.y) <= rm.halfH then
            local d2 = (wx - rm.x) ^ 2 + (wy - rm.y) ^ 2
            if d2 < bestDist then
                bestDist = d2
                hit = rm
            end
        end
    end

    if not isShift then
        SelectedMachines = {}
    end
    if hit then
        if isShift and SelectedMachines[hit.addr] then
            SelectedMachines[hit.addr] = nil
        else
            SelectedMachines[hit.addr] = hit
        end
    end
    RefreshSelectionLayer()
end

local function FinishBoxSelect(x1, y1, x2, y2, isShift)
    local wx1, wy1 = CanvasToWorld(math.min(x1, x2), math.min(y1, y2))
    local wx2, wy2 = CanvasToWorld(math.max(x1, x2), math.max(y1, y2))

    if not isShift then
        SelectedMachines = {}
    end
    for _, rm in ipairs(RenderedMachines) do
        if (rm.x + rm.halfW) >= wx1 and (rm.x - rm.halfW) <= wx2
            and (rm.y + rm.halfH) >= wy1 and (rm.y - rm.halfH) <= wy2
        then
            SelectedMachines[rm.addr] = rm
        end
    end
    RefreshSelectionLayer()
end

--------------------------------------------------------------------------------
-- Unified Mouse Polling Inside Map Canvas (Hover, Drag Box-Select, Pan, Ghosts)
--------------------------------------------------------------------------------

local function ZoomMapByFactor(factor, anchorMx, anchorMy)
    local mx = anchorMx or (ViewTransform.canvasW * 0.5)
    local my = anchorMy or (ViewTransform.canvasH * 0.5)
    local beforeWx, beforeWy = CanvasToWorld(mx, my)
    local newScale = Core.Clamp(ViewTransform.scale * factor, 0.04, 1.80)
    if math.abs(newScale - ViewTransform.scale) > 0.0001 then
        ViewTransform.scale = newScale
        ViewTransform.cx = beforeWx - (mx - ViewTransform.canvasW * 0.5) / newScale
        ViewTransform.cy = beforeWy - (my - ViewTransform.canvasH * 0.5) / newScale
        ApplyViewTransform()
        RefreshDynamicOverlay()
    end
end

local function GetMapCanvasCursorPos(pc)
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return nil, nil end
    local layoutLib = Core.GetCDO(PATHS.WidgetLayoutLibCDO)
    local slateLib = Core.GetCDO(PATHS.SlateLibCDO)
    if not (Core.IsValidObj(layoutLib) and Core.IsValidObj(slateLib) and MapUI.MapCanvas.GetCachedGeometry) then
        return nil, nil
    end

    local targetWidget = Core.IsValidObj(MapUI.MapBg) and MapUI.MapBg or MapUI.MapCanvas
    local okGeom, geom = pcall(function() return targetWidget:GetCachedGeometry() end)
    local lx, ly = nil, nil
    local absPos, vpPos = nil, nil

    if okGeom and geom and layoutLib.GetMousePositionOnPlatform and slateLib.AbsoluteToLocal then
        local okP, ap = pcall(function() return layoutLib:GetMousePositionOnPlatform() end)
        if okP and ap then
            absPos = ap
            local okL, localPos = pcall(function() return slateLib:AbsoluteToLocal(geom, ap) end)
            if okL and localPos then
                local tx = tonumber(localPos.X)
                local ty = tonumber(localPos.Y)
                if IsFiniteNum(tx) and IsFiniteNum(ty) then
                    lx, ly = tx, ty
                end
            end
        end
    end

    if (lx == nil or ly == nil) and Core.IsValidObj(pc) and layoutLib.GetMousePositionOnViewport and MapUI.Window then
        local okVP, vp = pcall(function() return layoutLib:GetMousePositionOnViewport(pc) end)
        if okVP and vp then
            vpPos = vp
            local vx, vy = tonumber(vp.X), tonumber(vp.Y)
            if IsFiniteNum(vx) and IsFiniteNum(vy) then
                local fullW, fullH = nil, nil
                if layoutLib.GetViewportSize then
                    local okVS, rawVp = pcall(function() return layoutLib:GetViewportSize(pc) end)
                    local vpScale = 1.0
                    pcall(function()
                        if layoutLib.GetViewportScale then
                            local s = tonumber(layoutLib:GetViewportScale(pc))
                            if IsFiniteNum(s) and s > 0.05 then vpScale = s end
                        end
                    end)
                    if okVS and rawVp and IsFiniteNum(tonumber(rawVp.X)) and IsFiniteNum(tonumber(rawVp.Y)) and rawVp.X > 100 then
                        fullW = rawVp.X / vpScale
                        fullH = rawVp.Y / vpScale
                    end
                end
                if (not fullW or not fullH) and slateLib.GetLocalSize then
                    local okWG, wGeom = pcall(function() return MapUI.Window:GetCachedGeometry() end)
                    if okWG and wGeom then
                        local okWS, wSz = pcall(function() return slateLib:GetLocalSize(wGeom) end)
                        if okWS and wSz and IsFiniteNum(tonumber(wSz.X)) and IsFiniteNum(tonumber(wSz.Y)) and wSz.X > 100 and wSz.Y > 100 then
                            fullW = wSz.X / 0.88
                            fullH = wSz.Y / 0.90
                        end
                    end
                end
                if fullW and fullH then
                    local winLeft = fullW * 0.06
                    local winTop = fullH * 0.05
                    lx = vx - (winLeft + 10.0)
                    ly = vy - (winTop + 66.0)
                end
            end
        end
    end

    if not CursorDiagLogged and (lx ~= nil) then
        CursorDiagLogged = true
        local ax = absPos and tonumber(absPos.X) or -999
        local ay = absPos and tonumber(absPos.Y) or -999
        if not vpPos and Core.IsValidObj(pc) and layoutLib.GetMousePositionOnViewport then
            pcall(function() vpPos = layoutLib:GetMousePositionOnViewport(pc) end)
        end
        local vpx = vpPos and tonumber(vpPos.X) or -999
        local vpy = vpPos and tonumber(vpPos.Y) or -999
        Core.Log(string.format("[StationMap] CursorDiag local=(%.1f,%.1f) abs=(%.1f,%.1f) vp=(%.1f,%.1f) canvas=(%.1f,%.1f)",
            lx or -999, ly or -999, ax, ay, vpx, vpy, ViewTransform.canvasW, ViewTransform.canvasH))
    end

    return lx, ly
end

local function IsAnyButtonHovered()
    if not MapUI then return false end
    for _, b in ipairs(TrackedButtons) do
        if Core.IsValidObj(b) and b.IsHovered then
            local okH, h = pcall(function() return b:IsHovered() end)
            if okH and h == true then return true end
        end
    end
    for _, b in ipairs(FloorRailButtons) do
        if Core.IsValidObj(b) and b.IsHovered then
            local okH, h = pcall(function() return b:IsHovered() end)
            if okH and h == true then return true end
        end
    end
    for _, ib in pairs(FloorIconButtons) do
        if Core.IsValidObj(ib.btn) and ib.btn.IsHovered then
            local okH, h = pcall(function() return ib.btn:IsHovered() end)
            if okH and h == true then return true end
        end
    end
    return false
end

local function EnsureInputPoll()
    if InputPollActive then return end
    InputPollActive = true

    local function Tick()
        if not IsMapOpen() or not MapUI then
            InputPollActive = false
            return
        end

        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then
            ExecuteInGameThreadAfterFrames(1, Tick)
            return
        end

        -- Keep character movement disabled while Station Map is open without touching BP_CameraPawn_C / movement components
        pcall(function()
            if pc.CharacterInputEnabled == true and pc.AllowCharacterInput then
                pc:AllowCharacterInput(false)
            end
            if pc.IsMoveInputIgnored and not pc:IsMoveInputIgnored() and pc.SetIgnoreMoveInput then
                pc:SetIgnoreMoveInput(true)
            end
            if pc.IsLookInputIgnored and not pc:IsLookInputIgnored() and pc.SetIgnoreLookInput then
                pc:SetIgnoreLookInput(true)
            end
        end)

        -- Fallback build-menu pickup if WBP_Building_C sets pc.Builder.Buildable, or reset if cancelled
        if WaitingForBuildMenuSelection then
            local picked = nil
            if Core.IsValidObj(pc.Builder) then
                local okB, bld = pcall(function() return pc.Builder.Buildable end)
                if okB and Core.IsValidObj(bld) then picked = bld end
            end
            if Core.IsValidObj(picked) then
                WaitingForBuildMenuSelection = false
                PendingBuildable = picked
                InteractionMode = "Place"
                PendingRotationDeg = 0
                pcall(function() pc:ExitBuildingMode() end)
                if MapUI and Core.IsValidObj(ActiveMapWin) then
                    pcall(function()
                        pc.bShowMouseCursor = true
                        local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
                        if Core.IsValidObj(wbl) then wbl:SetInputMode_GameAndUIEx(pc, ActiveMapWin, 0, false, false) end
                    end)
                end
                UpdateStatusBanner()
            elseif (os.clock() - (WaitingBuildMenuSince or 0)) > 0.35 and not Core.IsAnyWidgetClassVisible("WBP_Building_C") then
                WaitingForBuildMenuSelection = false
                if Core.IsValidObj(ActiveMapWin) then
                    pcall(function()
                        pc.bShowMouseCursor = true
                        local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
                        if Core.IsValidObj(wbl) then wbl:SetInputMode_GameAndUIEx(pc, ActiveMapWin, 0, false, false) end
                    end)
                end
            end
        end

        -- Detect layout size changes once canvas settles
        if MeasureMapCanvasSize() then
            if not ViewTransform.hasFitted then FitViewTransformToFloor() end
            ApplyViewTransform()
        end

        local mx, my = GetMapCanvasCursorPos(pc)
        local insideMap = (mx ~= nil and my ~= nil and mx >= 0 and mx <= ViewTransform.canvasW and my >= 0 and my <= ViewTransform.canvasH)

        local lDown, rDown, mDown, shiftDown, spaceDown = false, false, false, false, false
        local keyPanX, keyPanY = 0.0, 0.0
        local keyZoom = 0
        pcall(function()
            lDown = pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") }) == true
            rDown = pc:IsInputKeyDown({ KeyName = FName("RightMouseButton") }) == true
            mDown = pc:IsInputKeyDown({ KeyName = FName("MiddleMouseButton") }) == true
            shiftDown = (pc:IsInputKeyDown({ KeyName = FName("LeftShift") }) == true)
                or (pc:IsInputKeyDown({ KeyName = FName("RightShift") }) == true)
            spaceDown = pc:IsInputKeyDown({ KeyName = FName("SpaceBar") }) == true

            if not WaitingForBuildMenuSelection then
                if pc:IsInputKeyDown({ KeyName = FName("W") }) or pc:IsInputKeyDown({ KeyName = FName("Up") }) then keyPanY = keyPanY - 1.0 end
                if pc:IsInputKeyDown({ KeyName = FName("S") }) or pc:IsInputKeyDown({ KeyName = FName("Down") }) then keyPanY = keyPanY + 1.0 end
                if pc:IsInputKeyDown({ KeyName = FName("A") }) or pc:IsInputKeyDown({ KeyName = FName("Left") }) then keyPanX = keyPanX - 1.0 end
                if pc:IsInputKeyDown({ KeyName = FName("D") }) or pc:IsInputKeyDown({ KeyName = FName("Right") }) then keyPanX = keyPanX + 1.0 end
                if pc:WasInputKeyJustPressed({ KeyName = FName("Equals") }) or pc:WasInputKeyJustPressed({ KeyName = FName("Add") }) then keyZoom = 1 end
                if pc:WasInputKeyJustPressed({ KeyName = FName("Hyphen") }) or pc:WasInputKeyJustPressed({ KeyName = FName("Subtract") }) then keyZoom = -1 end
            end
        end)

        local cursorMoved = (mx ~= MouseState.lastCursorMx or my ~= MouseState.lastCursorMy)
        MouseState.lastCursorMx = mx
        MouseState.lastCursorMy = my

        -- Keyboard WASD/Arrow Pan (zero widget rebuild; instant GPU RenderTransform update!)
        if keyPanX ~= 0.0 or keyPanY ~= 0.0 then
            local stepCm = 14.0 / ViewTransform.scale
            ViewTransform.cx = ViewTransform.cx + keyPanX * stepCm
            ViewTransform.cy = ViewTransform.cy + keyPanY * stepCm
            ApplyViewTransform()
        end

        -- Handle Left Mouse Button transitions (Box Select / Click, or Space+LeftDrag to Pan)
        if lDown and not MouseState.wasLDown then
            if insideMap and not WaitingForBuildMenuSelection and not IsAnyButtonHovered() then
                MouseState.lDownInMap = true
                MouseState.lDraggingBox = false
                MouseState.lPanning = spaceDown
                MouseState.lStartX = mx
                MouseState.lStartY = my
                MouseState.lPanStartCx = ViewTransform.cx
                MouseState.lPanStartCy = ViewTransform.cy
            else
                MouseState.lDownInMap = false
                MouseState.lPanning = false
            end
        elseif lDown and MouseState.lDownInMap and mx and my then
            if MouseState.lPanning then
                if cursorMoved then
                    local dx = mx - MouseState.lStartX
                    local dy = my - MouseState.lStartY
                    ViewTransform.cx = MouseState.lPanStartCx - dx / ViewTransform.scale
                    ViewTransform.cy = MouseState.lPanStartCy - dy / ViewTransform.scale
                    ApplyViewTransform()
                end
            elseif InteractionMode == "Select" and not MouseState.lDraggingBox and insideMap then
                local dx = mx - MouseState.lStartX
                local dy = my - MouseState.lStartY
                if (dx * dx + dy * dy) > 36.0 then
                    MouseState.lDraggingBox = true
                end
            end
        elseif not lDown and MouseState.wasLDown then
            if MouseState.lDownInMap then
                if MouseState.lPanning and mx and my then
                    local dx = mx - MouseState.lStartX
                    local dy = my - MouseState.lStartY
                    ViewTransform.cx = MouseState.lPanStartCx - dx / ViewTransform.scale
                    ViewTransform.cy = MouseState.lPanStartCy - dy / ViewTransform.scale
                    ApplyViewTransform()
                elseif MouseState.lDraggingBox and mx and my then
                    FinishBoxSelect(MouseState.lStartX, MouseState.lStartY, mx, my, shiftDown)
                elseif insideMap then
                    HandleMapLeftClick(mx, my, shiftDown)
                end
            end
            MouseState.lDownInMap = false
            MouseState.lDraggingBox = false
            MouseState.lPanning = false
        end

        -- Handle Right or Middle Mouse Button (drag to pan anywhere over map at 120 FPS; quick right-click cancels Place/Paste)
        local panDown = rDown or mDown
        if panDown and not MouseState.wasRDown then
            if insideMap and not WaitingForBuildMenuSelection then
                MouseState.rDownInMap = true
                MouseState.rPanning = false
                MouseState.rStartX = mx
                MouseState.rStartY = my
                MouseState.panStartCx = ViewTransform.cx
                MouseState.panStartCy = ViewTransform.cy
            else
                MouseState.rDownInMap = false
            end
        elseif panDown and MouseState.rDownInMap and mx and my then
            local dx = mx - MouseState.rStartX
            local dy = my - MouseState.rStartY
            if not MouseState.rPanning and (dx * dx + dy * dy) > 25.0 then
                MouseState.rPanning = true
            end
            if MouseState.rPanning and cursorMoved then
                ViewTransform.cx = MouseState.panStartCx - dx / ViewTransform.scale
                ViewTransform.cy = MouseState.panStartCy - dy / ViewTransform.scale
                ApplyViewTransform()
            end
        elseif not panDown and MouseState.wasRDown then
            if MouseState.rDownInMap then
                if MouseState.rPanning and mx and my then
                    local dx = mx - MouseState.rStartX
                    local dy = my - MouseState.rStartY
                    ViewTransform.cx = MouseState.panStartCx - dx / ViewTransform.scale
                    ViewTransform.cy = MouseState.panStartCy - dy / ViewTransform.scale
                    ApplyViewTransform()
                elseif InteractionMode == "Place" or InteractionMode == "Paste" then
                    InteractionMode = "Select"
                    PendingBuildable = nil
                    UpdateStatusBanner()
                    RefreshDynamicOverlay()
                end
            end
            MouseState.rDownInMap = false
            MouseState.rPanning = false
        end

        -- Mouse Wheel (via ScrollBox offset delta + key/axis fallback) & +/- Keyboard Zoom
        if not WaitingForBuildMenuSelection then
            local scrollDelta = keyZoom
            if scrollDelta == 0 and MapUI and Core.IsValidObj(MapUI.WheelScrollBox) and MapUI.WheelScrollBox.GetScrollOffset then
                pcall(function()
                    local off = tonumber(MapUI.WheelScrollBox:GetScrollOffset())
                    if IsFiniteNum(off) and math.abs(off - 2000.0) > 0.25 then
                        scrollDelta = (off < 2000.0) and 1 or -1
                        MapUI.WheelScrollBox:SetScrollOffset(2000.0)
                    end
                end)
            end
            if scrollDelta == 0 then
                pcall(function()
                    if pc:WasInputKeyJustPressed({ KeyName = FName("MouseScrollUp") }) then scrollDelta = 1
                    elseif pc:WasInputKeyJustPressed({ KeyName = FName("MouseScrollDown") }) then scrollDelta = -1
                    elseif pc.GetInputAnalogKeyState then
                        local wAxis = tonumber(pc:GetInputAnalogKeyState({ KeyName = FName("MouseWheelAxis") })) or 0.0
                        if wAxis > 0.05 then scrollDelta = 1
                        elseif wAxis < -0.05 then scrollDelta = -1 end
                    end
                end)
            end
            if scrollDelta ~= 0 then
                ZoomMapByFactor((scrollDelta > 0) and 1.18 or (1.0 / 1.18), insideMap and mx or nil, insideMap and my or nil)
            end
        end

        MouseState.wasLDown = lDown
        MouseState.wasRDown = panDown

        -- Only rebuild screen-space overlay when dragging, placing/pasting, or hovering a different conveyor
        if MouseState.lDraggingBox or InteractionMode ~= "Select" then
            if cursorMoved or MouseState.lDraggingBox then
                RefreshDynamicOverlay()
            end
        elseif cursorMoved then
            local curPort = nil
            local curConv = nil
            if insideMap and not MouseState.rPanning then
                local wx, wy = CanvasToWorld(mx, my)
                for _, rp in ipairs(RenderedPorts) do
                    if math.abs(wx - rp.x) <= rp.halfW and math.abs(wy - rp.y) <= rp.halfH then
                        curPort = rp.idx
                        break
                    end
                end
                if not curPort and #RenderedConveyors > 0 then
                    for _, cm in ipairs(RenderedConveyors) do
                        if math.abs(wx - cm.x) <= cm.halfW and math.abs(wy - cm.y) <= cm.halfH then
                            curConv = cm.addr
                            break
                        end
                    end
                end
            end
            if curPort ~= LastHoveredPortIdx or curConv ~= LastHoveredConvAddr
                or ((curPort == nil and curConv == nil) and LastHadDynamicOverlay)
            then
                RefreshDynamicOverlay()
            end
        end

        ExecuteInGameThreadAfterFrames(1, Tick)
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

--------------------------------------------------------------------------------
-- Window Open / Close & Toolbar Actions
--------------------------------------------------------------------------------

local function SetStationMapCursorMode(pc, win, active)
    if not Core.IsValidObj(pc) then return end
    pcall(function()
        pc.bShowMouseCursor = active
        if active then
            if SavedCharInputEnabled == nil then
                SavedCharInputEnabled = (pc.CharacterInputEnabled == true)
            end
            if pc.AllowCharacterInput then pc:AllowCharacterInput(false) end
            if pc.SetIgnoreMoveInput then pc:SetIgnoreMoveInput(true) end
            if pc.SetIgnoreLookInput then pc:SetIgnoreLookInput(true) end
        else
            if pc.AllowCharacterInput then
                pc:AllowCharacterInput(SavedCharInputEnabled ~= false)
            end
            SavedCharInputEnabled = nil
            if pc.ResetIgnoreMoveInput then pc:ResetIgnoreMoveInput() end
            if pc.ResetIgnoreLookInput then pc:ResetIgnoreLookInput() end
            if pc.SetIgnoreMoveInput then pc:SetIgnoreMoveInput(false) end
            if pc.SetIgnoreLookInput then pc:SetIgnoreLookInput(false) end
        end
    end)
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) then
        pcall(function() widgetSub:SetCursorVisible(active) end)
    end
    local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
    if Core.IsValidObj(wbl) then
        pcall(function()
            if active then
                wbl:SetInputMode_GameAndUIEx(pc, win, 0, false, false)
            else
                wbl:SetInputMode_GameOnly(pc, false)
            end
        end)
    end
end

local function DestroyStationMap()
    CanvasRenderGen = CanvasRenderGen + 1
    MapWinVisible = false
    MapWinInViewport = false
    InteractionMode = "Select"
    PendingBuildable = nil
    WaitingForBuildMenuSelection = false
    RenderedMachines = {}
    RenderedConveyors = {}
    RenderedPorts = {}
    RenderedGridLines = {}
    LastGridTier = nil
    LastGridZoomRatio = nil
    LastHoveredPortIdx = nil
    FloorIconButtons = {}
    FloorRailButtons = {}
    TrackedButtons = {}
    if Core.IsValidObj(ActiveMapWin) then
        pcall(function() ActiveMapWin:RemoveFromParent() end)
    end
    ActiveMapWin = nil
    MapUI = nil
    SetStationMapCursorMode(Core.GetLocalPlayerController(), nil, false)
end

CloseStationMap = function()
    MapWinVisible = false
    InteractionMode = "Select"
    PendingBuildable = nil
    WaitingForBuildMenuSelection = false
    MouseState.lDownInMap = false
    MouseState.lDraggingBox = false
    MouseState.rDownInMap = false
    MouseState.rPanning = false
    if Core.IsValidObj(ActiveMapWin) then
        pcall(function() ActiveMapWin:SetVisibility(1) end) -- Collapsed (keeps UMG tree cached for instant re-open)
    end
    SetStationMapCursorMode(Core.GetLocalPlayerController(), nil, false)
end

local function OpenBuildMenuFromStationMap()
    local pc = Core.GetLocalPlayerController()
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    local bldCls = Core.FindOrLoadClass(PATHS.BuildingMenuClass)
    if not (Core.IsValidObj(pc) and Core.IsValidObj(widgetSub) and Core.IsValidObj(bldCls)) then
        return
    end

    WaitingBuildMenuSince = os.clock()
    WaitingForBuildMenuSelection = true
    pcall(function()
        widgetSub:ShowWindow(bldCls, nil, nil, false)
    end)
end

local function OpenStationMap()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
    if not inStation or not Core.IsValidObj(walkFrame) then
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

    -- Fast path: reuse hidden Station Map window for the same station (instant <5ms re-open)
    if MapWinInViewport and Core.IsValidObj(ActiveMapWin) and MapUI and Core.IsValidObj(CurrentStation) and Core.IsValidObj(station)
        and CurrentStation:GetAddress() == station:GetAddress()
    then
        local tFast = os.clock()
        MapWinVisible = true
        pcall(function() ActiveMapWin:SetVisibility(0) end) -- Visible
        SetStationMapCursorMode(pc, ActiveMapWin, true)
        MouseState.wasLDown = false
        MouseState.wasRDown = false
        MouseState.lDownInMap = false
        MouseState.lDraggingBox = false
        MouseState.rDownInMap = false
        MouseState.rPanning = false
        EnsureInputPoll()
        RefreshDynamicOverlay()
        Core.Log(string.format("[StationMap] Reused cached map window in %.1fms", (os.clock() - tFast) * 1000.0))
        return
    end

    if Core.IsValidObj(ActiveMapWin) then
        DestroyStationMap()
    end

    local win = Core.CreateUserWidget(PATHS.WindowBaseClass, pc, pc)
    if not Core.IsValidObj(win) then
        Core.Log("StationMap: failed to construct WBP_WindowBase_C")
        return
    end

    ActiveMapWin = win
    MapWinVisible = true
    MapWinInViewport = true
    local outer = Core.GetWidgetOuter(win)

    pcall(function()
        win:SetWindowName(Core.MakeText("Station Map"))
        win:AddToViewport(50)
        win:SetAnchorsInViewport({ Minimum = { X = 0.06, Y = 0.05 }, Maximum = { X = 0.94, Y = 0.95 } })
    end)
    SetStationMapCursorMode(pc, win, true)

    local rootVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local topHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local bodyHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local mapBg = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local mapOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    local bgPanZoom = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local mapCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local selectionCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local wheelScrollBox = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local wheelSpacer = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local iconPanZoom = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local iconCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local overlayCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local rightVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local statusText = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)

    if not (Core.IsValidObj(rootVBox) and Core.IsValidObj(topHBox) and Core.IsValidObj(bodyHBox)
        and Core.IsValidObj(mapBg) and Core.IsValidObj(mapOverlay) and Core.IsValidObj(bgPanZoom)
        and Core.IsValidObj(mapCanvas) and Core.IsValidObj(selectionCanvas)
        and Core.IsValidObj(overlayCanvas) and Core.IsValidObj(rightVBox)) then
        CloseStationMap()
        return
    end

    TrackedButtons = {}
    CursorDiagLogged = false
    LastHoveredConvAddr = nil
    LastHadDynamicOverlay = false

    pcall(function()
        mapBg:SetBrushColor(COLORS.WindowBg)
        mapBg:SetClipping(1)
        mapOverlay:SetClipping(1)
        bgPanZoom:SetClipping(0)
        bgPanZoom:SetVisibility(4) -- SelfHitTestInvisible
        mapCanvas:SetClipping(0)
        selectionCanvas:SetClipping(0)
        selectionCanvas:SetVisibility(4)
        overlayCanvas:SetClipping(1)
        overlayCanvas:SetVisibility(4) -- SelfHitTestInvisible

        local mcSlot = bgPanZoom:AddChildToCanvas(mapCanvas)
        if Core.IsValidObj(mcSlot) then
            mcSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            mcSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            mcSlot:SetZOrder(0)
        end
        local scSlot = bgPanZoom:AddChildToCanvas(selectionCanvas)
        if Core.IsValidObj(scSlot) then
            scSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            scSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            scSlot:SetZOrder(1)
        end
        local bpSlot = mapOverlay:AddChildToOverlay(bgPanZoom)
        if Core.IsValidObj(bpSlot) then
            bpSlot:SetHorizontalAlignment(0)
            bpSlot:SetVerticalAlignment(0)
        end

        if Core.IsValidObj(wheelScrollBox) and Core.IsValidObj(wheelSpacer) then
            wheelSpacer:SetHeightOverride(5000.0)
            wheelSpacer:SetVisibility(4)
            wheelScrollBox:AddChild(wheelSpacer)
            pcall(function()
                wheelScrollBox:SetScrollBarVisibility(1) -- Collapsed
                wheelScrollBox.bAllowRightClickDragScrolling = false
                wheelScrollBox.bAnimateWheelScrolling = false
                wheelScrollBox.ConsumeMouseWheel = 1 -- Always
                wheelScrollBox:SetScrollOffset(2000.0)
            end)
            local wsSlot = mapOverlay:AddChildToOverlay(wheelScrollBox)
            if Core.IsValidObj(wsSlot) then
                wsSlot:SetHorizontalAlignment(0)
                wsSlot:SetVerticalAlignment(0)
            end
        end

        if Core.IsValidObj(iconPanZoom) and Core.IsValidObj(iconCanvas) then
            iconPanZoom:SetClipping(0)
            iconPanZoom:SetVisibility(4)
            iconCanvas:SetClipping(0)
            iconCanvas:SetVisibility(4) -- SelfHitTestInvisible; child icon buttons remain clickable!
            local icChildSlot = iconPanZoom:AddChildToCanvas(iconCanvas)
            if Core.IsValidObj(icChildSlot) then
                icChildSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                icChildSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end
            local icSlot = mapOverlay:AddChildToOverlay(iconPanZoom)
            if Core.IsValidObj(icSlot) then
                icSlot:SetHorizontalAlignment(0)
                icSlot:SetVerticalAlignment(0)
            end
        end
        local ovSlot = mapOverlay:AddChildToOverlay(overlayCanvas)
        if Core.IsValidObj(ovSlot) then
            ovSlot:SetHorizontalAlignment(0)
            ovSlot:SetVerticalAlignment(0)
        end
        mapBg:AddChild(mapOverlay)

        local attached = false
        if Core.IsValidObj(win.Content) then
            local okC = pcall(function() win.Content:AddChild(rootVBox) end)
            if okC then attached = true end
        end
        if not attached and Core.IsValidObj(win.ContentBorder) then
            pcall(function() win.ContentBorder:AddChild(rootVBox) end)
        end
        win:SetContentForSlot(FName("Content"), rootVBox)
    end)

    -- Top compact strip: status + zoom + quick helpers
    if Core.IsValidObj(statusText) then
        local stSlot = topHBox:AddChildToHorizontalBox(statusText)
        if Core.IsValidObj(stSlot) then
            pcall(function()
                stSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                stSlot:SetVerticalAlignment(2)
            end)
        end
        pcall(function()
            statusText:SetVisibility(3)
            statusText:SetSize(12)
        end)
    end

    local zoomInWrap = CreateLabeledButton(win, pc, outer, "+", 14, 30.0, 28.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        ZoomMapByFactor(1.22)
    end)
    local zoomOutWrap = CreateLabeledButton(win, pc, outer, "-", 14, 30.0, 28.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        ZoomMapByFactor(1.0 / 1.22)
    end)
    local fitWrap = CreateLabeledButton(win, pc, outer, "Fit", 11, 40.0, 28.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        FitViewTransformToFloor()
        ApplyViewTransform()
        RefreshDynamicOverlay()
    end)
    local buildWrap = CreateLabeledButton(win, pc, outer, "Build (B)", 11, 74.0, 28.0, COLORS.FloorNormal, COLORS.PlayerLocal, OpenBuildMenuFromStationMap)
    local copyWrap, copyBtn = CreateLabeledButton(win, pc, outer, "Copy", 11, 56.0, 28.0, COLORS.FloorNormal, COLORS.PlayerLocal, CopySelectedMachines)
    local rotWrap, rotBtn = CreateLabeledButton(win, pc, outer, "Rotate (R)", 11, 80.0, 28.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        PendingRotationDeg = (PendingRotationDeg + 90) % 360
        UpdateStatusBanner()
        RefreshDynamicOverlay()
    end)
    local clearWrap, clearBtn = CreateLabeledButton(win, pc, outer, "Clear", 11, 56.0, 28.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        SelectedMachines = {}
        RefreshSelectionLayer()
    end)
    for _, tb in ipairs({ zoomInWrap, zoomOutWrap, fitWrap, buildWrap, copyWrap, rotWrap, clearWrap }) do
        if Core.IsValidObj(tb) then
            local sl = topHBox:AddChildToHorizontalBox(tb)
            if Core.IsValidObj(sl) then
                pcall(function() sl:SetPadding({ Left = 4.0, Top = 0.0, Right = 0.0, Bottom = 0.0 }) end)
            end
        end
    end

    local topSlot = rootVBox:AddChildToVerticalBox(topHBox)
    if Core.IsValidObj(topSlot) then
        pcall(function()
            topSlot:SetPadding({ Left = 8.0, Top = 4.0, Right = 8.0, Bottom = 6.0 })
            topSlot:SetHorizontalAlignment(0)
        end)
    end

    -- Body left: Gridded Map Viewport (expands to fill available space)
    local mapSlot = bodyHBox:AddChildToHorizontalBox(mapBg)
    if Core.IsValidObj(mapSlot) then
        pcall(function()
            mapSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            mapSlot:SetHorizontalAlignment(0)
            mapSlot:SetVerticalAlignment(0)
        end)
    end

    -- Body right: Vertical Paginated Floor Selector (middle) + Bottom-Right Apply Changes (bottom)
    local floorFrame = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local floorInnerVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local floorSlotsBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local floorUpWrap, floorUpBtn = CreateLabeledButton(win, pc, outer, "^", 16, 96.0, 40.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        local total = #CurrentFloors
        if total > FLOOR_PAGE_SIZE and FloorPageTopIdx and FloorPageTopIdx < total then
            FloorPageTopIdx = math.min(total, FloorPageTopIdx + 1)
            RebuildFloorButtons()
        end
    end)
    local floorDownWrap, floorDownBtn = CreateLabeledButton(win, pc, outer, "v", 16, 96.0, 40.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        local minTop = math.min(#CurrentFloors, FLOOR_PAGE_SIZE)
        if FloorPageTopIdx and FloorPageTopIdx > minTop then
            FloorPageTopIdx = math.max(minTop, FloorPageTopIdx - 1)
            RebuildFloorButtons()
        end
    end)

    if Core.IsValidObj(floorFrame) and Core.IsValidObj(floorInnerVBox) and Core.IsValidObj(floorSlotsBox) then
        pcall(function()
            floorFrame:SetBrushColor(COLORS.FloorRailBg)
            floorFrame:SetPadding({ Left = 8.0, Top = 12.0, Right = 8.0, Bottom = 12.0 })
            if Core.IsValidObj(floorUpWrap) then
                local uSlot = floorInnerVBox:AddChildToVerticalBox(floorUpWrap)
                if Core.IsValidObj(uSlot) then
                    uSlot:SetPadding({ Left = 4, Top = 0, Right = 4, Bottom = 8 })
                    uSlot:SetHorizontalAlignment(2)
                end
            end
            local fsSlot = floorInnerVBox:AddChildToVerticalBox(floorSlotsBox)
            if Core.IsValidObj(fsSlot) then
                fsSlot:SetHorizontalAlignment(2)
                fsSlot:SetVerticalAlignment(2)
                fsSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            end
            if Core.IsValidObj(floorDownWrap) then
                local dSlot = floorInnerVBox:AddChildToVerticalBox(floorDownWrap)
                if Core.IsValidObj(dSlot) then
                    dSlot:SetPadding({ Left = 4, Top = 8, Right = 4, Bottom = 0 })
                    dSlot:SetHorizontalAlignment(2)
                end
            end
            floorFrame:AddChild(floorInnerVBox)
        end)
    end

    if Core.IsValidObj(floorFrame) then
        local fWrapSlot = rightVBox:AddChildToVerticalBox(floorFrame)
        if Core.IsValidObj(fWrapSlot) then
            pcall(function()
                fWrapSlot:SetHorizontalAlignment(2) -- Center wider floor rail horizontally
                fWrapSlot:SetVerticalAlignment(0)   -- Fill vertical height above Apply button
                fWrapSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                fWrapSlot:SetPadding({ Left = 0.0, Top = 6.0, Right = 0.0, Bottom = 12.0 })
            end)
        end
    end

    local applyWrap, applyBtn, applyBtnText = CreateLabeledButton(win, pc, outer, "Apply Changes", 12, 148.0, 40.0, { R = 0.14, G = 0.36, B = 0.20, A = 0.96 }, COLORS.PlayerLocal, function()
        Core.Log(string.format("[StationMap] ApplyBtn pressed (pending=%d)", #PendingGhosts))
        ExecuteInGameThreadWithDelay(10, CommitPendingGhosts)
    end)
    local discardWrap, discardBtn = CreateLabeledButton(win, pc, outer, "Discard", 11, 148.0, 30.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        PendingGhosts = {}
        RefreshSelectionLayer()
    end)

    if Core.IsValidObj(discardWrap) then
        pcall(function() discardWrap:SetVisibility(2) end)
        local dSlot = rightVBox:AddChildToVerticalBox(discardWrap)
        if Core.IsValidObj(dSlot) then
            pcall(function()
                dSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 6.0 })
                dSlot:SetHorizontalAlignment(2)
            end)
        end
    end
    if Core.IsValidObj(applyWrap) then
        local aSlot = rightVBox:AddChildToVerticalBox(applyWrap)
        if Core.IsValidObj(aSlot) then
            pcall(function() aSlot:SetHorizontalAlignment(2) end)
        end
    end

    local rightBoxWrap = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    pcall(function()
        rightBoxWrap:SetMinDesiredWidth(164.0)
        rightBoxWrap:AddChild(rightVBox)
    end)
    local rightBodySlot = bodyHBox:AddChildToHorizontalBox(rightBoxWrap)
    if Core.IsValidObj(rightBodySlot) then
        pcall(function()
            rightBodySlot:SetPadding({ Left = 10.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            rightBodySlot:SetVerticalAlignment(0)
        end)
    end

    local bodySlot = rootVBox:AddChildToVerticalBox(bodyHBox)
    if Core.IsValidObj(bodySlot) then
        pcall(function()
            bodySlot:SetSize({ Value = 1.0, SizeRule = 1 })
            bodySlot:SetHorizontalAlignment(0)
            bodySlot:SetVerticalAlignment(0)
            bodySlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 8.0, Bottom = 8.0 })
        end)
    end

    if Core.IsValidObj(win.WBP_WindowHeader) and Core.IsValidObj(win.WBP_WindowHeader.CloseButton) then
        Core.RegisterWBPButtonClick(win.WBP_WindowHeader.CloseButton, CloseStationMap)
    end

    MapUI = {
        Window = win,
        PC = pc,
        MapBg = mapBg,
        BgPanZoom = bgPanZoom,
        MapCanvas = mapCanvas,
        SelectionCanvas = selectionCanvas,
        WheelScrollBox = wheelScrollBox,
        IconPanZoom = iconPanZoom,
        IconCanvas = iconCanvas,
        OverlayCanvas = overlayCanvas,
        FloorSlotsBox = floorSlotsBox,
        FloorUpBtn = floorUpWrap,
        FloorDownBtn = floorDownWrap,
        ApplyBtn = applyWrap,
        ApplyBtnText = applyBtnText,
        DiscardBtn = discardWrap,
        CopyBtn = copyBtn,
        RotateBtn = rotBtn,
        ClearSelBtn = clearBtn,
        StatusText = statusText,
    }

    local px, py, pz = 0.0, 0.0, 0.0
    if Core.IsValidObj(pc.Pawn) then
        local okLoc, loc = pcall(function() return pc.Pawn:K2_GetActorLocation() end)
        if okLoc and loc then
            px = loc.X or 0.0
            py = loc.Y or 0.0
            pz = loc.Z or 0.0
        end
    end

    CurrentStation = station
    CurrentWalkFrame = walkFrame
    local t0 = os.clock()
    local floors, curIdx, _, gox, goy, xform = StationData.BuildStationFloorMap(station, walkFrame, px, py, pz)
    local t1 = os.clock()
    CurrentFrameXform = xform
    CurrentFloors = floors
    SelectedFloorIdx = curIdx
    FloorPageTopIdx = nil
    ViewTransform.gridOriginX = gox or 0.0
    ViewTransform.gridOriginY = goy or 0.0
    ViewTransform.hasFitted = false
    SelectedMachines = {}
    InteractionMode = "Select"
    MouseState.wasLDown = false
    MouseState.wasRDown = false
    MouseState.lDownInMap = false
    MouseState.lDraggingBox = false
    MouseState.rDownInMap = false
    MouseState.rPanning = false

    RebuildFloorButtons()
    RefreshStationMapCanvas()
    local t2 = os.clock()
    Core.Log(string.format("[StationMap] OpenTiming build=%.0fms canvas=%.0fms total=%.0fms floor=%d machines=%d walls=%d ports=%d",
        (t1 - t0) * 1000.0, (t2 - t1) * 1000.0, (t2 - t0) * 1000.0,
        SelectedFloorIdx, #RenderedMachines,
        (CurrentFloors[SelectedFloorIdx] and CurrentFloors[SelectedFloorIdx].walls and #CurrentFloors[SelectedFloorIdx].walls) or 0,
        #RenderedPorts))
    EnsureInputPoll()

    -- Re-fit once after UMG finishes layout pass on frame 2, and pre-inspect BuildMachineCommand signature
    ExecuteInGameThreadAfterFrames(2, function()
        InspectBuildMachineCommandLayout()
        if IsMapOpen() and MeasureMapCanvasSize() then
            FitViewTransformToFloor()
            ApplyViewTransform()
        end
    end)
end

local function ToggleStationMap()
    if IsMapOpen() then
        CloseStationMap()
    else
        OpenStationMap()
    end
end

--------------------------------------------------------------------------------
-- Keybinds inside Station Map (B = Build, R = Rotate, Ctrl+C = Copy, Esc = Cancel)
--------------------------------------------------------------------------------

local function EnsureMapKeybinds()
    if KeyHandlersBound or not Key then return end
    KeyHandlersBound = true

    if Key.B then
        RegisterKeyBind(Key.B, function()
            if IsMapOpen() and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(OpenBuildMenuFromStationMap)
            end
        end)
    end

    if Key.R then
        RegisterKeyBind(Key.R, function()
            if IsMapOpen() and (InteractionMode == "Place" or InteractionMode == "Paste") and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(function()
                    PendingRotationDeg = (PendingRotationDeg + 90) % 360
                    UpdateStatusBanner()
                    RefreshDynamicOverlay()
                end)
            end
        end)
    end

    if Key.C and ModifierKey and ModifierKey.CONTROL then
        RegisterKeyBind(Key.C, { ModifierKey.CONTROL }, function()
            if IsMapOpen() and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(CopySelectedMachines)
            end
        end)
    elseif Key.C then
        RegisterKeyBind(Key.C, function()
            if IsMapOpen() and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(function()
                    local pc = Core.GetLocalPlayerController()
                    local ctrlDown = false
                    if Core.IsValidObj(pc) then
                        pcall(function()
                            ctrlDown = (pc:IsInputKeyDown({ KeyName = FName("LeftControl") }) == true)
                                or (pc:IsInputKeyDown({ KeyName = FName("RightControl") }) == true)
                        end)
                    end
                    if ctrlDown then
                        CopySelectedMachines()
                    end
                end)
            end
        end)
    end

    if Key.ESCAPE then
        RegisterKeyBind(Key.ESCAPE, function()
            if IsMapOpen() and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(function()
                    if InteractionMode ~= "Select" then
                        InteractionMode = "Select"
                        PendingBuildable = nil
                        UpdateStatusBanner()
                        RefreshDynamicOverlay()
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

function Feature.Init()
    LastWorldAddr = GetCurrentWorldAddr()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "StationMapKey",
        DefaultKey  = "N",
        MappingName = "Eqol_StationMap",
        Label       = "Station Map",
        OnPress     = ToggleStationMap,
        CanTrigger  = function()
            return IsMapOpen() or nil
        end,
    })
    EnsureMapKeybinds()
    StationData.OnIconVisibilityChanged(function()
        if IsMapOpen() then
            pcall(RefreshStationMapCanvas)
        end
    end)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "DMSPlayerController_AddBuildMachineCommand_Diag",
        "/Script/MainSequence.DMSPlayerController:AddBuildMachineCommand",
        function(Context, CmdParam)
            pcall(function()
                local st = Core.UnwrapStruct(CmdParam) or (CmdParam and CmdParam.get and CmdParam:get()) or CmdParam
                if st then
                    local gx, gy = "?", "?"
                    if st.GridLocation then
                        gx, gy = tostring(st.GridLocation.X), tostring(st.GridLocation.Y)
                    end
                    local bName = Core.IsValidObj(st.Buildable) and st.Buildable:GetFName():ToString() or "nil"
                    Core.Log(string.format("[StationMap] RecvBuildCmd: platId=%s grid=(%s,%s) h=%s rot=%s cfg=%s bld=%s",
                        tostring(st.PlatformID), gx, gy, tostring(st.Height), tostring(st.Rotation), tostring(st.Config), bName))
                end
            end)
        end
    )

    Core.TryRegisterHook(
        "DMSPlayerController_AddBuildCommand_Diag",
        "/Script/MainSequence.DMSPlayerController:AddBuildCommand",
        function(Context, CmdParam)
            Core.Log("[StationMap] RecvAddBuildCommand fired!")
        end
    )

    Core.TryRegisterHook(
        "DMSPlayerController_ConfirmBuild_Diag",
        "/Script/MainSequence.DMSPlayerController:ConfirmBuild",
        function(Context)
            Core.Log("[StationMap] RecvConfirmBuild fired!")
        end
    )

    Core.TryRegisterHook(
        "DMSPlayerController_SetBuildError_Diag",
        "/Script/MainSequence.DMSPlayerController:SetBuildError",
        function(Context, ErrParam)
            pcall(function()
                local eVal = Core.UnwrapArrayElem(ErrParam)
                local eStr = (eVal and eVal.ToString and eVal:ToString()) or tostring(eVal)
                if eStr and eStr ~= "" then
                    Core.Log("[StationMap] BuildError: " .. eStr)
                end
            end)
        end
    )

    Core.TryRegisterHook(
        "WindowBase_CloseWindow_StationMap",
        "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C:BndEvt__WBP_WindowBase_WBP_WindowHeader_K2Node_ComponentBoundEvent_1_CloseWindow__DelegateSignature",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) and Core.IsValidObj(ActiveMapWin) and w:GetAddress() == ActiveMapWin:GetAddress() then
                DestroyStationMap()
            end
        end
    )

    Core.TryRegisterHook(
        "Building_BuildableSelected_StationMap",
        "/Game/Blueprints/Widgets/Menus/WBP_Building.WBP_Building_C:BuildableSelected",
        function(Context, BuildableParam)
            if not WaitingForBuildMenuSelection or not IsMapOpen() then
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
                    SetStationMapCursorMode(pc, ActiveMapWin, true)
                end
                UpdateStatusBanner()
                RefreshDynamicOverlay()
            end
        end
    )
end

local function ScheduleStationPrewarm()
    local curWorld = GetCurrentWorldAddr()
    if not curWorld or PrewarmScheduledForWorld == curWorld then return end
    PrewarmScheduledForWorld = curWorld
    ExecuteInGameThreadWithDelay(2500, function()
        if GetCurrentWorldAddr() ~= curWorld or IsMapOpen() then return end
        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then return end
        local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
        if inStation and Core.IsValidObj(station) then
            local t0 = os.clock()
            local floors = StationData.BuildStationFloorMap(station, walkFrame, nil, nil, nil)
            if floors and #floors > 0 and #CurrentFloors == 0 then
                CurrentFloors = floors
            end
            InspectBuildMachineCommandLayout()
            Core.Log(string.format("[StationMap] Prewarmed station caches in %.0fms", (os.clock() - t0) * 1000.0))
        end
    end)
end

function Feature.OnClientRestart()
    local curWorld = GetCurrentWorldAddr()
    if curWorld == nil or curWorld ~= LastWorldAddr then
        LastWorldAddr = curWorld
        PrewarmScheduledForWorld = nil
        if Core.IsValidObj(ActiveMapWin) then DestroyStationMap() end
        ResetSpriteCache()
        PendingGhosts = {}
        Clipboard = {}
    end
    ScheduleStationPrewarm()
end

function Feature.OnMapLoad()
    LastWorldAddr = GetCurrentWorldAddr()
    PrewarmScheduledForWorld = nil
    if Core.IsValidObj(ActiveMapWin) then DestroyStationMap() end
    ResetSpriteCache()
    PendingGhosts = {}
    Clipboard = {}
    ScheduleStationPrewarm()
end

function Feature.PruneCaches()
    for addr, btn in pairs(MapHudInjected) do
        if not Core.IsValidObj(btn) then
            MapHudInjected[addr] = nil
        end
    end
    if ActiveMapWin and not Core.IsValidObj(ActiveMapWin) then
        ActiveMapWin = nil
        MapWinVisible = false
        MapWinInViewport = false
        MapUI = nil
    end
end

return Feature
