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
local FLOOR_PAGE_SIZE = 5
local DEFAULT_CANVAS_W = 1060.0
local DEFAULT_CANVAS_H = 740.0

local COLORS = {
    WindowBg      = { R = 0.024, G = 0.032, B = 0.044, A = 0.96 },
    GridLine      = { R = 0.140, G = 0.175, B = 0.220, A = 0.45 },
    GridMajor     = { R = 0.200, G = 0.250, B = 0.315, A = 0.55 },
    ModuleFill    = { R = 0.075, G = 0.100, B = 0.135, A = 0.96 },
    ModuleBorder  = { R = 0.520, G = 0.620, B = 0.740, A = 0.92 },
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
local MapUI = nil

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
local FloorIconButtons = {}  -- mAddr -> { btn, widget }
local FloorRailButtons = {}  -- list of WBP_Button_C instances in floor selector
local TrackedButtons = {}    -- list of static WBP_Button_C instances for hover check
local IconDiagLogged = false
local CursorDiagLogged = false
local LastPanRedrawClock = 0.0

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
    local tex = StationData.GetBuildableIconTexture(machine, buildableOpt)
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

    local entry = {
        tex = tex,
        bgCol = bgCol,
        borderCol = borderCol,
        typeKey = typeKey,
        tier = tier,
        directional = directional,
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

local function InspectBuildMachineCommandLayout()
    if CachedBuildCmdLayout then return CachedBuildCmdLayout end
    local ufunc = StaticFindObject("/Script/MainSequence.DMSPlayerController:AddBuildMachineCommand")
    if not Core.IsValidObj(ufunc) then return nil end

    local layout = { params = {}, firstStructFields = nil, firstStructName = nil }
    pcall(function()
        ufunc:ForEachProperty(function(prop)
            local pName = prop:GetFName():ToString()
            table.insert(layout.params, pName)
            if not layout.firstStructFields and prop.GetStruct then
                local okS, st = pcall(function() return prop:GetStruct() end)
                if okS and Core.IsValidObj(st) and st.ForEachProperty then
                    layout.firstStructName = pName
                    layout.firstStructFields = {}
                    st:ForEachProperty(function(fp)
                        local fName = fp:GetFName():ToString()
                        local fCls = ""
                        pcall(function() fCls = fp:GetClass():GetFName():ToString() end)
                        layout.firstStructFields[fName] = fCls
                    end)
                end
            end
        end)
    end)
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

local function IssueRemoteBuildMachine(pc, station, platform, platBounds, buildable, wx, wy, wz, yawDeg, recipe)
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

    local fb = platBounds or StationData.GetPlatformWorldBounds(targetFrame)
    local relX = wx - fb.cx
    local relY = wy - fb.cy
    local relZ = wz - fb.cz

    local quat = {
        X = 0.0,
        Y = 0.0,
        Z = math.sin(math.rad((yawDeg or 0.0) * 0.5)),
        W = math.cos(math.rad((yawDeg or 0.0) * 0.5)),
    }
    local relTransform = {
        Rotation = quat,
        Translation = { X = relX, Y = relY, Z = relZ },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local worldTransform = {
        Rotation = quat,
        Translation = { X = wx, Y = wy, Z = wz },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local platId = 0
    if Core.IsValidObj(platform) then
        pcall(function() if platform.ID ~= nil then platId = tonumber(platform.ID) or 0 end end)
    end
    local gx = math.floor(relX / 50.0 + 0.5)
    local gy = math.floor(relY / 50.0 + 0.5)
    local gz = math.floor(relZ / 50.0 + 0.5)
    local rotSteps = ((math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4) + 4) % 4

    local cmdSuccess = false
    local layout = InspectBuildMachineCommandLayout()
    if layout and layout.firstStructFields then
        local cmd = {}
        local fields = layout.firstStructFields
        local function setIfField(name, val)
            if fields[name] ~= nil then cmd[name] = val end
        end
        setIfField("FrameID", targetFrame.ID)
        setIfField("StationID", targetFrame.ID)
        setIfField("Frame", targetFrame)
        setIfField("PlatformID", platId)
        setIfField("Platform", platform)
        setIfField("Buildable", buildable)
        setIfField("BuildBlock", buildable)
        setIfField("GridLocation", { X = gx, Y = gy, Z = gz })
        setIfField("GridRotation", rotSteps)
        setIfField("Rotation", { Pitch = 0.0, Yaw = yawDeg or 0.0, Roll = 0.0 })
        setIfField("Yaw", yawDeg or 0.0)
        setIfField("LocalQuat", quat)
        setIfField("Quat", quat)
        setIfField("Transform", relTransform)
        setIfField("Location", { X = relX, Y = relY, Z = relZ })

        local okCmd = pcall(function() pc:AddBuildMachineCommand(cmd) end)
        if okCmd then cmdSuccess = true end
    end

    if not cmdSuccess then
        local attempts = {
            function() pc:AddBuildMachineCommand(targetFrame, buildable, relTransform) end,
            function() pc:AddBuildMachineCommand(buildable, targetFrame, relTransform) end,
            function() pc:AddBuildMachineCommand(targetFrame, buildable, worldTransform) end,
            function()
                pc:AddBuildMachineCommand({
                    FrameID = targetFrame.ID,
                    PlatformID = platId,
                    Frame = targetFrame,
                    Buildable = buildable,
                    GridLocation = { X = gx, Y = gy, Z = gz },
                    GridRotation = rotSteps,
                    Transform = relTransform,
                    Location = { X = relX, Y = relY, Z = relZ },
                    Rotation = { Pitch = 0.0, Yaw = yawDeg or 0.0, Roll = 0.0 },
                })
            end,
        }
        for _, fn in ipairs(attempts) do
            if pcall(fn) then
                cmdSuccess = true
                break
            end
        end
    end

    if not cmdSuccess then
        return false, "Build command failed"
    end

    if Core.IsValidObj(recipe) then
        ExecuteInGameThreadWithDelay(250, function()
            StationData.InvalidateCaches()
            local machines = StationData.GetAllStationMachines(CurrentStation, { platform }, CurrentWalkFrame)
            local bestM, bestDist = nil, 150.0
            for _, m in ipairs(machines) do
                if StationData.GetMachineCategory(m) == "Assembler" then
                    local mx, my = StationData.GetMachineWorldPosAndYaw(m, fb)
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

local function CreateMachineVisualWidget(parentWindow, pc, outer, targetCanvas, mx, my, pxW, pxH, yawDeg, cat, spriteEntry, isGhost, validGhost, zBase, hasBottomOverlay)
    local fillW = math.max(6.0, pxW - 2.0)
    local fillH = math.max(6.0, pxH - 2.0)

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
            local availH = shiftUp and (fillH * 0.56) or (fillH * 0.80)
            local availW = fillW * 0.80
            local iconDim = math.max(6.0, math.min(availW, availH))
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
    local edges = {
        { x = cx, y = cy - halfH, ew = w, eh = t }, -- Top
        { x = cx, y = cy + halfH, ew = w, eh = t }, -- Bottom
        { x = cx - halfW, y = cy, ew = t, eh = h }, -- Left
        { x = cx + halfW, y = cy, ew = t, eh = h }, -- Right
    }
    for _, e in ipairs(edges) do
        local b = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if Core.IsValidObj(b) then
            pcall(function() b:SetBrushColor(col) end)
            local s = canvas:AddChildToCanvas(b)
            SetCanvasSlot(s, e.x, e.y, e.ew, e.eh, 0.5, 0.5, zOrder)
        end
    end
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

    local spanX = math.max(1200.0, maxX - minX)
    local spanY = math.max(1200.0, maxY - minY)
    local pad = 90.0
    local availW = math.max(300.0, ViewTransform.canvasW - pad)
    local availH = math.max(300.0, ViewTransform.canvasH - pad)

    ViewTransform.cx = (minX + maxX) * 0.5
    ViewTransform.cy = (minY + maxY) * 0.5
    ViewTransform.scale = Core.Clamp(math.min(availW / spanX, availH / spanY), 0.05, 0.75)
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
            local hasMat = PlayerHasBuildableMaterials(pc, gp.buildable, 1)
            local valid = onMod and hasMat
            local rx, ry = GetRotatedCellDims(gp.cellsX, gp.cellsY, gp.yaw)
            local pxW = rx * cellPx
            local pxH = ry * cellPx

            CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.OverlayCanvas, gmx, gmy, pxW, pxH, gp.yaw, "Other", gp.sprite, true, valid, 55, false)
            RenderBorderOutline(outer, MapUI.OverlayCanvas, gmx, gmy, pxW, pxH, 2.0, valid and COLORS.GhostBorderOk or COLORS.GhostBorderBad, 56)
        end
    end

    -- 3. Conveyor item hover tooltip (only shown while cursor hovers a conveyor carrying an item)
    if InteractionMode == "Select" and not MouseState.lDraggingBox and not MouseState.rPanning
        and MouseState.lastCursorMx and MouseState.lastCursorMy
        and MouseState.lastCursorMx >= 0 and MouseState.lastCursorMx <= ViewTransform.canvasW
        and MouseState.lastCursorMy >= 0 and MouseState.lastCursorMy <= ViewTransform.canvasH
    then
        local wx, wy = CanvasToWorld(MouseState.lastCursorMx, MouseState.lastCursorMy)
        local hoveredConv = nil
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

RefreshStationMapCanvas = function()
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return end

    MeasureMapCanvasSize()
    if not ViewTransform.hasFitted then
        FitViewTransformToFloor()
    end

    ClearCanvasChildren(MapUI.MapCanvas)
    ClearCanvasChildren(MapUI.IconCanvas)
    RenderedMachines = {}
    RenderedConveyors = {}
    FloorIconButtons = {}

    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor or #floor.platforms == 0 then
        UpdateStatusBanner("No station modules on this floor")
        RefreshDynamicOverlay()
        return
    end

    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = MapUI.PC
    local cw, ch = ViewTransform.canvasW, ViewTransform.canvasH
    local scale = ViewTransform.scale
    local cellPx = CELL_CM * scale

    -- Visible world bounds for grid line clipping
    local visMinX, visMinY = CanvasToWorld(0.0, 0.0)
    local visMaxX, visMaxY = CanvasToWorld(cw, ch)

    -- 1. Full background 1x1 cell grid lines (step by >1 cell only if zoomed way out < 6px/cell)
    local cellStep = 1
    if cellPx < 6.0 then cellStep = 4
    elseif cellPx < 10.0 then cellStep = 2 end
    local stepCm = CELL_CM * cellStep

    local startGx = math.floor((visMinX - ViewTransform.gridOriginX) / stepCm) * stepCm + ViewTransform.gridOriginX
    local gx = startGx
    local maxLines = 220
    local drawnV = 0
    while gx <= visMaxX and drawnV < maxLines do
        drawnV = drawnV + 1
        local mx = WorldToCanvas(gx, ViewTransform.cy)
        local line = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if Core.IsValidObj(line) then
            local isMajor = (math.abs(((gx - ViewTransform.gridOriginX) / CELL_CM) % 4) < 0.01)
            pcall(function() line:SetBrushColor(isMajor and COLORS.GridMajor or COLORS.GridLine) end)
            local s = MapUI.MapCanvas:AddChildToCanvas(line)
            SetCanvasSlot(s, mx, ch * 0.5, 1.5, ch, 0.5, 0.5, 1)
        end
        gx = gx + stepCm
    end

    local startGy = math.floor((visMinY - ViewTransform.gridOriginY) / stepCm) * stepCm + ViewTransform.gridOriginY
    local gy = startGy
    local drawnH = 0
    while gy <= visMaxY and drawnH < maxLines do
        drawnH = drawnH + 1
        local my = WorldToCanvas(ViewTransform.cx, gy)
        local line = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if Core.IsValidObj(line) then
            local isMajor = (math.abs(((gy - ViewTransform.gridOriginY) / CELL_CM) % 4) < 0.01)
            pcall(function() line:SetBrushColor(isMajor and COLORS.GridMajor or COLORS.GridLine) end)
            local s = MapUI.MapCanvas:AddChildToCanvas(line)
            SetCanvasSlot(s, cw * 0.5, my, cw, 1.5, 0.5, 0.5, 1)
        end
        gy = gy + stepCm
    end

    -- 2. Render station modules (interior fill + crisp 4-edge module borders)
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        local mx, my = WorldToCanvas(b.cx, b.cy)
        local mw = math.max(12.0, b.ex * 2.0 * scale)
        local mh = math.max(12.0, b.ey * 2.0 * scale)

        local modFill = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if Core.IsValidObj(modFill) then
            pcall(function() modFill:SetBrushColor(COLORS.ModuleFill) end)
            local slot = MapUI.MapCanvas:AddChildToCanvas(modFill)
            SetCanvasSlot(slot, mx, my, mw, mh, 0.5, 0.5, 2)
        end
        RenderBorderOutline(outer, MapUI.MapCanvas, mx, my, mw, mh, 2.0, COLORS.ModuleBorder, 4)
    end

    -- 3. Collect & render placed machines on this floor
    local floorMachines = floor.machines
    if not floorMachines or #floorMachines == 0 then
        -- Safety fallback: gather from StationData directly if floor.machines wasn't populated
        floorMachines = {}
        local seen = {}
        local allM = StationData.GetAllStationMachines(CurrentStation, {}, CurrentWalkFrame)
        for _, m in ipairs(allM) do
            local addr = m:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                local mwx, mwy, mwz, myaw = StationData.GetMachineWorldPosAndYaw(m, floor.platforms[1] and floor.platforms[1].bounds)
                if math.abs(mwz - floor.z) <= 350.0 then
                    table.insert(floorMachines, { machine = m, x = mwx, y = mwy, z = mwz, yaw = myaw })
                end
            end
        end
        floor.machines = floorMachines
    end

    for _, me in ipairs(floorMachines) do
        local m = me.machine
        if Core.IsValidObj(m) then
            local mwx, mwy, mwz, myaw = me.x, me.y, me.z, me.yaw
            local mx, my = WorldToCanvas(mwx, mwy)
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
            local isSel = SelectedMachines[mAddr] ~= nil

            -- Prepare Container items OR Producer output items & rates/min
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
            end

            CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.MapCanvas, mx, my, pxW, pxH, myaw, cat, sprite, false, true, isSel and 16 or 10, hasBottomOverlay)

            if isSel then
                local selFill = Core.CreateRawWidget(PATHS.BorderClass, outer)
                if Core.IsValidObj(selFill) then
                    pcall(function() selFill:SetBrushColor(COLORS.SelectedFill) end)
                    local ss = MapUI.MapCanvas:AddChildToCanvas(selFill)
                    SetCanvasSlot(ss, mx, my, pxW, pxH, 0.5, 0.5, 17)
                end
                RenderBorderOutline(outer, MapUI.MapCanvas, mx, my, pxW, pxH, 2.0, COLORS.Selected, 18)
            end

            -- Clickable item / production-rate badge overlays on Containers (items only) & Producers (items + rate/min)
            if hasBottomOverlay then
                local isHidden = StationData.IsMachineIconHidden(m)
                local iconSize = Core.Clamp(math.min(pxW * (#overlayChips > 1 and 0.34 or 0.50), pxH * 0.36), 14.0, 26.0)
                local badgeW = #overlayChips * (iconSize + 10.0) + ((#overlayChips > 1) and 4.0 or 0.0)
                if isProducer then
                    badgeW = math.max(badgeW, #overlayChips * math.max(38.0, iconSize + 18.0))
                end
                local badgeH = isProducer and (iconSize + 16.0) or (iconSize + 6.0)
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
                                        rTxt:SetSize(9)
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

    -- 4. Render queued pending ghost placements on this floor (awaiting Apply Changes)
    for _, gp in ipairs(PendingGhosts) do
        if math.abs((gp.z or floor.z) - floor.z) <= 250.0 then
            local gmx, gmy = WorldToCanvas(gp.x, gp.y)
            local rx, ry = GetRotatedCellDims(gp.cellsX or 1, gp.cellsY or 1, gp.yaw or 0)
            local pxW = math.max(8.0, rx * cellPx)
            local pxH = math.max(8.0, ry * cellPx)
            local sprite = gp.actorClsPath and RequestMachineSprite(gp.actorClsPath, nil, "Other", gp.buildable) or gp.sprite
            CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.MapCanvas, gmx, gmy, pxW, pxH, gp.yaw or 0, "Other", sprite, true, true, 22, false)
            RenderBorderOutline(outer, MapUI.MapCanvas, gmx, gmy, pxW, pxH, 1.5, COLORS.GhostBorderOk, 23)
        end
    end

    -- 5. Render player markers & nametags on this floor (converted into station-local space)
    local allPlayers = StationData.GetAllPlayersInfo(pc)
    for _, p in ipairs(allPlayers) do
        if p.HasPos then
            local plx, ply, plz = StationData.WorldToStationLocal(CurrentFrameXform, p.X, p.Y, p.Z, nil, nil, nil)
            if math.abs(plz - floor.z) <= 220.0 then
                local pmx, pmy = WorldToCanvas(plx, ply)
                local pDot = Core.CreateRawWidget(PATHS.BorderClass, outer)
                if Core.IsValidObj(pDot) then
                    local col = p.IsLocal and COLORS.PlayerLocal or (p.IsOnline and COLORS.PlayerOnline or COLORS.PlayerOffline)
                    pcall(function() pDot:SetBrushColor(col) end)
                    local pSlot = MapUI.MapCanvas:AddChildToCanvas(pDot)
                    SetCanvasSlot(pSlot, pmx, pmy, 10.0, 10.0, 0.5, 0.5, 45)
                end
                local nameTxt = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, pc)
                if Core.IsValidObj(nameTxt) then
                    local nSlot = MapUI.MapCanvas:AddChildToCanvas(nameTxt)
                    SetCanvasSlot(nSlot, pmx, pmy - 14.0, 120.0, 18.0, 0.5, 1.0, 46)
                    pcall(function()
                        nameTxt:SetVisibility(3)
                        nameTxt:SetSize(10)
                        nameTxt:SetText(Core.MakeText(p.Name))
                    end)
                end
            end
        end
    end

    UpdateActionBar()
    UpdateStatusBanner()
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
            MapUI.Window, MapUI.PC, outer, tostring(thisIdx), 18, 96.0, 72.0, bgCol, txtCol,
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
                    slot:SetPadding({ Left = 4.0, Top = 6.0, Right = 4.0, Bottom = 6.0 })
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

    local builtCount = 0
    local remaining = {}
    local lastErr = nil

    for _, g in ipairs(PendingGhosts) do
        local targetFloor = CurrentFloors[g.floorIdx] or CurrentFloors[SelectedFloorIdx]
        local plat, pb = FindPlatformAtWorldXY(g.x, g.y, targetFloor)
        local wx, wy, wz = StationData.StationLocalToWorld(CurrentFrameXform, g.x, g.y, g.z)
        local ok, err = IssueRemoteBuildMachine(pc, CurrentStation, plat, pb, g.buildable, wx, wy, wz, g.yaw, g.recipe)
        if ok then
            builtCount = builtCount + 1
        else
            lastErr = err
            table.insert(remaining, g)
        end
    end

    PendingGhosts = remaining
    UpdateActionBar()

    if builtCount > 0 then
        UpdateStatusBanner(string.format("Applied %d placement(s)%s", builtCount, (#remaining > 0 and (" (" .. #remaining .. " failed)") or "")))
        ExecuteInGameThreadWithDelay(250, function()
            StationData.InvalidateCaches()
            if CurrentFloors[SelectedFloorIdx] then
                CurrentFloors[SelectedFloorIdx].machines = nil
            end
            if Core.IsValidObj(ActiveMapWin) then
                RefreshStationMapCanvas()
            end
        end)
    elseif lastErr then
        UpdateStatusBanner("Apply failed: " .. tostring(lastErr))
        RefreshStationMapCanvas()
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
        RefreshStationMapCanvas()
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
                if IsPointOverAnyFloorModule(sx, sy, floor) then
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
        RefreshStationMapCanvas()
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
    RefreshStationMapCanvas()
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
    RefreshStationMapCanvas()
end

--------------------------------------------------------------------------------
-- Unified Mouse Polling Inside Map Canvas (Hover, Drag Box-Select, Pan, Ghosts)
--------------------------------------------------------------------------------

local function ZoomMapByFactor(factor, anchorMx, anchorMy)
    local mx = anchorMx or (ViewTransform.canvasW * 0.5)
    local my = anchorMy or (ViewTransform.canvasH * 0.5)
    local beforeWx, beforeWy = CanvasToWorld(mx, my)
    local newScale = Core.Clamp(ViewTransform.scale * factor, 0.03, 1.50)
    if math.abs(newScale - ViewTransform.scale) > 0.0001 then
        ViewTransform.scale = newScale
        ViewTransform.cx = beforeWx - (mx - ViewTransform.canvasW * 0.5) / newScale
        ViewTransform.cy = beforeWy - (my - ViewTransform.canvasH * 0.5) / newScale
        RefreshStationMapCanvas()
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
        if not Core.IsValidObj(ActiveMapWin) or not MapUI then
            InputPollActive = false
            return
        end

        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then
            ExecuteInGameThreadAfterFrames(1, Tick)
            return
        end

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
            RefreshStationMapCanvas()
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

        -- Keyboard WASD/Arrow Pan (smooth pan scaled to current zoom)
        local nowClk = os.clock()
        if (keyPanX ~= 0.0 or keyPanY ~= 0.0) and (nowClk - LastPanRedrawClock) >= 0.03 then
            local stepCm = 28.0 / ViewTransform.scale
            ViewTransform.cx = ViewTransform.cx + keyPanX * stepCm
            ViewTransform.cy = ViewTransform.cy + keyPanY * stepCm
            LastPanRedrawClock = nowClk
            RefreshStationMapCanvas()
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
                if cursorMoved and (nowClk - LastPanRedrawClock) >= 0.03 then
                    local dx = mx - MouseState.lStartX
                    local dy = my - MouseState.lStartY
                    ViewTransform.cx = MouseState.lPanStartCx - dx / ViewTransform.scale
                    ViewTransform.cy = MouseState.lPanStartCy - dy / ViewTransform.scale
                    LastPanRedrawClock = nowClk
                    RefreshStationMapCanvas()
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
                    RefreshStationMapCanvas()
                elseif MouseState.lDraggingBox and mx and my then
                    FinishBoxSelect(MouseState.lStartX, MouseState.lStartY, mx, my, shiftDown)
                elseif insideMap and not IsAnyButtonHovered() then
                    HandleMapLeftClick(mx, my, shiftDown)
                end
            end
            MouseState.lDownInMap = false
            MouseState.lDraggingBox = false
            MouseState.lPanning = false
        end

        -- Handle Right or Middle Mouse Button (drag to pan anywhere over map, quick right-click cancels Place/Paste)
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
            if MouseState.rPanning and cursorMoved and (nowClk - LastPanRedrawClock) >= 0.03 then
                ViewTransform.cx = MouseState.panStartCx - dx / ViewTransform.scale
                ViewTransform.cy = MouseState.panStartCy - dy / ViewTransform.scale
                LastPanRedrawClock = nowClk
                RefreshStationMapCanvas()
            end
        elseif not panDown and MouseState.wasRDown then
            if MouseState.rDownInMap then
                if MouseState.rPanning and mx and my then
                    local dx = mx - MouseState.rStartX
                    local dy = my - MouseState.rStartY
                    ViewTransform.cx = MouseState.panStartCx - dx / ViewTransform.scale
                    ViewTransform.cy = MouseState.panStartCy - dy / ViewTransform.scale
                    RefreshStationMapCanvas()
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

        if cursorMoved or MouseState.lDraggingBox then
            RefreshDynamicOverlay()
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
            if pc.SetIgnoreMoveInput then pc:SetIgnoreMoveInput(true) end
            if pc.SetIgnoreLookInput then pc:SetIgnoreLookInput(true) end
        else
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

CloseStationMap = function()
    InteractionMode = "Select"
    PendingBuildable = nil
    WaitingForBuildMenuSelection = false
    RenderedMachines = {}
    RenderedConveyors = {}
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
        win:SetAnchorsInViewport({ Minimum = { X = 0.06, Y = 0.05 }, Maximum = { X = 0.94, Y = 0.95 } })
    end)
    SetStationMapCursorMode(pc, win, true)

    local rootVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local topHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local bodyHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local mapBg = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local mapOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    local mapCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local wheelScrollBox = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local wheelSpacer = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local iconCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local overlayCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local rightVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local statusText = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)

    if not (Core.IsValidObj(rootVBox) and Core.IsValidObj(topHBox) and Core.IsValidObj(bodyHBox)
        and Core.IsValidObj(mapBg) and Core.IsValidObj(mapOverlay) and Core.IsValidObj(mapCanvas)
        and Core.IsValidObj(overlayCanvas) and Core.IsValidObj(rightVBox)) then
        CloseStationMap()
        return
    end

    TrackedButtons = {}
    CursorDiagLogged = false

    pcall(function()
        mapBg:SetBrushColor(COLORS.WindowBg)
        mapCanvas:SetClipping(1)
        overlayCanvas:SetClipping(1)
        overlayCanvas:SetVisibility(4) -- SelfHitTestInvisible
        local mcSlot = mapOverlay:AddChildToOverlay(mapCanvas)
        if Core.IsValidObj(mcSlot) then
            mcSlot:SetHorizontalAlignment(0) -- Fill
            mcSlot:SetVerticalAlignment(0)   -- Fill
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
        if Core.IsValidObj(iconCanvas) then
            iconCanvas:SetClipping(1)
            iconCanvas:SetVisibility(4) -- SelfHitTestInvisible; child icon buttons remain clickable!
            local icSlot = mapOverlay:AddChildToOverlay(iconCanvas)
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
        RefreshStationMapCanvas()
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
        RefreshStationMapCanvas()
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
    local floorUpWrap, floorUpBtn = CreateLabeledButton(win, pc, outer, "^", 16, 96.0, 44.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        local total = #CurrentFloors
        if total > FLOOR_PAGE_SIZE and FloorPageTopIdx and FloorPageTopIdx < total then
            FloorPageTopIdx = math.min(total, FloorPageTopIdx + 1)
            RebuildFloorButtons()
        end
    end)
    local floorDownWrap, floorDownBtn = CreateLabeledButton(win, pc, outer, "v", 16, 96.0, 44.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
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

    local applyWrap, applyBtn, applyBtnText = CreateLabeledButton(win, pc, outer, "Apply Changes", 12, 148.0, 40.0, { R = 0.14, G = 0.36, B = 0.20, A = 0.96 }, COLORS.PlayerLocal, CommitPendingGhosts)
    local discardWrap, discardBtn = CreateLabeledButton(win, pc, outer, "Discard", 11, 148.0, 30.0, COLORS.FloorNormal, COLORS.PlayerLocal, function()
        PendingGhosts = {}
        UpdateActionBar()
        RefreshStationMapCanvas()
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
        MapCanvas = mapCanvas,
        WheelScrollBox = wheelScrollBox,
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
    local floors, curIdx, _, gox, goy, xform = StationData.BuildStationFloorMap(station, walkFrame, px, py, pz)
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
    EnsureInputPoll()

    -- Re-fit once after UMG finishes layout pass on frame 2
    ExecuteInGameThreadAfterFrames(2, function()
        if Core.IsValidObj(ActiveMapWin) and MeasureMapCanvasSize() then
            FitViewTransformToFloor()
            RefreshStationMapCanvas()
        end
    end)
end

local function ToggleStationMap()
    if Core.IsValidObj(ActiveMapWin) then
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
            if Core.IsValidObj(ActiveMapWin) and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(OpenBuildMenuFromStationMap)
            end
        end)
    end

    if Key.R then
        RegisterKeyBind(Key.R, function()
            if Core.IsValidObj(ActiveMapWin) and (InteractionMode == "Place" or InteractionMode == "Paste") and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(function()
                    PendingRotationDeg = (PendingRotationDeg + 90) % 360
                    UpdateStatusBanner()
                    RefreshDynamicOverlay()
                end)
            end
        end)
    end

    if Key.C then
        RegisterKeyBind(Key.C, function()
            if Core.IsValidObj(ActiveMapWin) and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
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
            if Core.IsValidObj(ActiveMapWin) and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
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
            return Core.IsValidObj(ActiveMapWin) or nil
        end,
    })
    EnsureMapKeybinds()
    StationData.OnIconVisibilityChanged(function()
        if Core.IsValidObj(ActiveMapWin) then
            pcall(RefreshStationMapCanvas)
        end
    end)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "WindowBase_CloseWindow_StationMap",
        "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C:BndEvt__WBP_WindowBase_WBP_WindowHeader_K2Node_ComponentBoundEvent_1_CloseWindow__DelegateSignature",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) and Core.IsValidObj(ActiveMapWin) and w:GetAddress() == ActiveMapWin:GetAddress() then
                CloseStationMap()
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
                    SetStationMapCursorMode(pc, ActiveMapWin, true)
                end
                UpdateStatusBanner()
                RefreshDynamicOverlay()
            end
        end
    )
end

function Feature.OnClientRestart()
    local curWorld = GetCurrentWorldAddr()
    if curWorld == nil or curWorld ~= LastWorldAddr then
        LastWorldAddr = curWorld
        if Core.IsValidObj(ActiveMapWin) then CloseStationMap() end
        ResetSpriteCache()
        PendingGhosts = {}
        Clipboard = {}
    end
end

function Feature.OnMapLoad()
    LastWorldAddr = GetCurrentWorldAddr()
    if Core.IsValidObj(ActiveMapWin) then CloseStationMap() end
    ResetSpriteCache()
    PendingGhosts = {}
    Clipboard = {}
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
