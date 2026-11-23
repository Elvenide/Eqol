-- Eqol Station Map Tiled RenderTarget2D (UCanvas) Renderer
-- Replaces thousands of UMG Border/Image/UserWidget instances with a small grid of GPU
-- UTextureRenderTarget2D tiles (1 UImage per 16x16 cell tile) drawn via native UCanvas C++ calls.
-- 100% save-safe, zero cooked assets, automatic fallback to UMG if BeginDrawCanvasToRenderTarget is unavailable.

local Core = require("core")
local StationData = require("station_data")

local RT = {}

RT.TILE_WORLD_CM = 1600.0 -- 16x16 station cells per tile
RT.TILE_PX       = 768    -- 48 px/cell (~2.25 MB VRAM per active tile, matches 46 px/cell UMG sharpness)
RT.PX_PER_CM     = RT.TILE_PX / RT.TILE_WORLD_CM

local UV0          = { X = 0.0, Y = 0.0 }
local UV1          = { X = 1.0, Y = 1.0 }
local PIVOT_CENTER = { X = 0.5, Y = 0.5 }
local COL_WHITE    = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local COL_CLEAR    = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
local COL_SHADOW   = { R = 0.0, G = 0.0, B = 0.0, A = 0.85 }
local COL_OUTLINE  = { R = 0.0, G = 0.0, B = 0.0, A = 0.90 }
local COL_CHIP_BG  = { R = 0.03, G = 0.04, B = 0.06, A = 0.78 }
local COL_PORT_OUT = { R = 0.0, G = 0.0, B = 0.0, A = 0.98 }
local COL_PORT_IN  = { R = 0.08, G = 0.10, B = 0.14, A = 0.90 }
local COL_CHEVRON  = { R = 1.0, G = 0.86, B = 0.14, A = 0.98 }
local COL_GRID_MIN = { R = 0.24, G = 0.29, B = 0.37, A = 0.30 }
local COL_GRID_MAJ = { R = 0.30, G = 0.37, B = 0.48, A = 0.50 }
local BLEND_TRANSLUCENT = 2 -- EBlendMode::BLEND_Translucent
local RTF_RGBA8 = 6         -- ETextureRenderTargetFormat::RTF_RGBA8

local CachedKRL = nil
local CachedWhiteTex = nil
local WhiteTexSearched = false
local CachedFont = nil
local FontSearched = false
local CachedImageCls = nil
local ItemTexCache = {} -- itemAddr -> UTexture2D or false
local ProbeDone = false
local ProbeSucceeded = false

local function GetKRL()
    if not Core.IsValidObj(CachedKRL) then
        CachedKRL = Core.GetCDO("/Script/Engine.Default__KismetRenderingLibrary")
    end
    return Core.IsValidObj(CachedKRL) and CachedKRL or nil
end

local function GetWhiteTex()
    if Core.IsValidObj(CachedWhiteTex) then return CachedWhiteTex end
    if WhiteTexSearched then return nil end
    WhiteTexSearched = true
    for _, path in ipairs({
        "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture",
        "/Engine/ArtTools/RenderToTexture/Textures/127grey.127grey",
    }) do
        local t = Core.FindOrLoadClass(path)
        if Core.IsValidObj(t) then
            CachedWhiteTex = t
            return t
        end
    end
    return nil
end

local function GetDrawFont()
    if Core.IsValidObj(CachedFont) then return CachedFont end
    if FontSearched then return nil end
    FontSearched = true
    for _, path in ipairs({
        "/Engine/EngineFonts/Roboto.Roboto",
        "/Engine/EngineFonts/RobotoTiny.RobotoTiny",
    }) do
        local f = Core.FindOrLoadClass(path)
        if Core.IsValidObj(f) then
            CachedFont = f
            return f
        end
    end
    pcall(function()
        local f = FindFirstOf("Font")
        if Core.IsValidObj(f) then CachedFont = f end
    end)
    return Core.IsValidObj(CachedFont) and CachedFont or nil
end

local function GetItemTexture(item)
    if not Core.IsValidObj(item) then return nil end
    local addr = item:GetAddress()
    local cached = ItemTexCache[addr]
    if cached ~= nil then
        return (cached ~= false and Core.IsValidObj(cached)) and cached or nil
    end
    local tex = StationData.GetBuildableIconTexture(nil, item)
    if Core.IsValidObj(tex) then
        ItemTexCache[addr] = tex
        return tex
    end
    ItemTexCache[addr] = false
    return nil
end

-- Resolves UCanvas and FDrawToRenderTargetContext regardless of UE4SS out-param convention
local function BeginDrawRT(krl, worldCtx, rt)
    local outCanvas = {}
    local outSize = {}
    local outCtx = {}
    local ok, r1, r2, r3 = pcall(function()
        return krl:BeginDrawCanvasToRenderTarget(worldCtx, rt, outCanvas, outSize, outCtx)
    end)
    if not ok then
        return nil, nil, tostring(r1)
    end

    local canvas = nil
    if Core.IsValidObj(outCanvas) then
        canvas = outCanvas
    elseif type(outCanvas) == "table" then
        if Core.IsValidObj(outCanvas.Canvas) then canvas = outCanvas.Canvas
        elseif Core.IsValidObj(outCanvas[1]) then canvas = outCanvas[1] end
    end
    if not Core.IsValidObj(canvas) and Core.IsValidObj(r1) then
        canvas = r1
    end

    local ctx = outCtx
    if type(outCtx) == "table" and outCtx.Context ~= nil then
        ctx = outCtx.Context
    elseif r3 ~= nil and (type(outCtx) ~= "table" or next(outCtx) == nil) then
        ctx = r3
    end

    if not Core.IsValidObj(canvas) then
        return nil, nil, "BeginDrawCanvasToRenderTarget returned nil Canvas"
    end
    return canvas, ctx, nil
end

local function EndDrawRT(krl, worldCtx, ctx)
    pcall(function()
        krl:EndDrawCanvasToRenderTarget(worldCtx, ctx)
    end)
end

local function CreateRT2D(krl, worldCtx, w, h)
    -- UE 5.7 CreateRenderTarget2D takes 7 params (added bSupportUAVs=false); fallback to 6 params for older UE
    local ok, rt = pcall(function()
        return krl:CreateRenderTarget2D(worldCtx, w, h, RTF_RGBA8, COL_CLEAR, false, false)
    end)
    if ok and Core.IsValidObj(rt) then return true, rt end
    local ok6, rt6 = pcall(function()
        return krl:CreateRenderTarget2D(worldCtx, w, h, RTF_RGBA8, COL_CLEAR, false)
    end)
    if ok6 and Core.IsValidObj(rt6) then return true, rt6 end
    return false, rt or rt6
end

-- Probes once whether UE 5.7 BeginDrawCanvasToRenderTarget works cleanly in UE4SS
function RT.IsSupported(worldCtx)
    if ProbeDone then return ProbeSucceeded end
    ProbeDone = true
    ProbeSucceeded = false

    local krl = GetKRL()
    if not Core.IsValidObj(krl) or not Core.IsValidObj(worldCtx)
        or not krl.CreateRenderTarget2D or not krl.BeginDrawCanvasToRenderTarget or not krl.EndDrawCanvasToRenderTarget
    then
        Core.Log("[StationMapRT] Probe failed: KismetRenderingLibrary functions unavailable")
        return false
    end

    local okRT, testRT = CreateRT2D(krl, worldCtx, 64, 64)
    if not okRT or not Core.IsValidObj(testRT) then
        Core.Log("[StationMapRT] Probe failed: CreateRenderTarget2D err=" .. tostring(testRT))
        return false
    end

    local canvas, ctx, err = BeginDrawRT(krl, worldCtx, testRT)
    if not Core.IsValidObj(canvas) then
        Core.Log("[StationMapRT] Probe failed: " .. tostring(err))
        return false
    end

    local okDraw, drawErr = pcall(function()
        canvas:K2_DrawLine({ X = 0.0, Y = 0.0 }, { X = 10.0, Y = 10.0 }, 1.0, COL_WHITE)
    end)
    EndDrawRT(krl, worldCtx, ctx)

    if not okDraw then
        Core.Log("[StationMapRT] Probe failed: K2_DrawLine err=" .. tostring(drawErr))
        return false
    end

    ProbeSucceeded = true
    local wt = GetWhiteTex()
    local ft = GetDrawFont()
    Core.Log(string.format("[StationMapRT] Probe succeeded! whiteTex=%s font=%s",
        tostring(Core.IsValidObj(wt)), tostring(Core.IsValidObj(ft))))
    return true
end

function RT.ResetCaches()
    ItemTexCache = {}
    CachedImageCls = nil
    -- Keep ProbeDone/ProbeSucceeded, whiteTex, font across floor switches
end

--------------------------------------------------------------------------------
-- Canvas Drawing Primitives (Tile Pixel Space)
--------------------------------------------------------------------------------

local function DrawFilledRect(canvas, whiteTex, cx, cy, w, h, col, angleDeg)
    if w <= 0.1 or h <= 0.1 then return end
    canvas:K2_DrawTexture(
        whiteTex,
        { X = cx - w * 0.5, Y = cy - h * 0.5 },
        { X = w, Y = h },
        UV0, UV1,
        col,
        BLEND_TRANSLUCENT,
        angleDeg or 0.0,
        PIVOT_CENTER
    )
end

local function DrawSprite(canvas, tex, cx, cy, w, h, col, angleDeg)
    if not Core.IsValidObj(tex) or w <= 0.1 or h <= 0.1 then return end
    canvas:K2_DrawTexture(
        tex,
        { X = cx - w * 0.5, Y = cy - h * 0.5 },
        { X = w, Y = h },
        UV0, UV1,
        col or COL_WHITE,
        BLEND_TRANSLUCENT,
        angleDeg or 0.0,
        PIVOT_CENTER
    )
end

local function DrawLine(canvas, x1, y1, x2, y2, thickness, col)
    canvas:K2_DrawLine({ X = x1, Y = y1 }, { X = x2, Y = y2 }, thickness, col)
end

local function DrawChevron(canvas, whiteTex, cx, cy, armLen, armThick, yawDeg, col)
    local halfArm = armLen * 0.3536
    local rad = math.rad(yawDeg or 0.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)
    for _, sign in ipairs({ -1.0, 1.0 }) do
        local lx = -halfArm * 0.2
        local ly = sign * halfArm
        local rx = lx * cosA - ly * sinA
        local ry = lx * sinA + ly * cosA
        DrawFilledRect(canvas, whiteTex, cx + rx, cy + ry, armLen, armThick, col, (yawDeg or 0.0) - sign * 45.0)
    end
end

local function DrawDashedLine(canvas, x1, y1, x2, y2, col, thickness, dashLen, gapLen)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 4.0 then return end
    local dLen = dashLen or 10.0
    local gLen = gapLen or 6.0
    local step = dLen + gLen
    local ux, uy = dx / dist, dy / dist
    local t = 4.0
    while t < dist - 4.0 do
        local segLen = math.min(dLen, (dist - 4.0) - t)
        if segLen >= 2.0 then
            DrawLine(canvas, x1 + ux * t, y1 + uy * t, x1 + ux * (t + segLen), y1 + uy * (t + segLen), thickness, col)
        end
        t = t + step
    end
end

local function DrawSplitterOrBalancerChevrons(canvas, whiteTex, mx, my, pxW, pxH, yawDeg, clsLow)
    local isSplitter = clsLow:find("splitter", 1, true) ~= nil
    local isBalancer = clsLow:find("balancer", 1, true) ~= nil
    if not isSplitter and not isBalancer then return end

    local rad = math.rad(yawDeg or 0.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)
    local function toTile(lx, ly)
        return mx + (lx * cosA - ly * sinA), my + (lx * sinA + ly * cosA)
    end

    local norm = (math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4 + 4) % 4
    local unrotW = (norm == 1 or norm == 3) and pxH or pxW
    local unrotH = (norm == 1 or norm == 3) and pxW or pxH
    local armLen = math.max(5.0, math.min(unrotW, unrotH) * 0.20)
    local armThick = math.max(1.6, math.min(2.4, armLen * 0.26))

    if isSplitter then
        local edgeX = unrotW * 0.38
        local edgeY = unrotH * 0.38
        local bx, by = toTile(-edgeX, 0.0)
        DrawChevron(canvas, whiteTex, bx, by, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
        local fx, fy = toTile(edgeX, 0.0)
        DrawChevron(canvas, whiteTex, fx, fy, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
        local lx, ly = toTile(0.0, -edgeY)
        DrawChevron(canvas, whiteTex, lx, ly, armLen, armThick, (yawDeg or 0.0) - 90.0, COL_CHEVRON)
        local rx, ry = toTile(0.0, edgeY)
        DrawChevron(canvas, whiteTex, rx, ry, armLen, armThick, (yawDeg or 0.0) + 90.0, COL_CHEVRON)
    elseif isBalancer then
        local edgeX = unrotW * 0.36
        local laneY = unrotH * 0.25
        for _, sideSign in ipairs({ -1.0, 1.0 }) do
            local ix, iy = toTile(-edgeX, sideSign * laneY)
            DrawChevron(canvas, whiteTex, ix, iy, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
            local ox, oy = toTile(edgeX, sideSign * laneY)
            DrawChevron(canvas, whiteTex, ox, oy, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
        end
    end
end

--------------------------------------------------------------------------------
-- Tiled Floor Renderer Instance
--------------------------------------------------------------------------------

function RT.CreateFloorRenderer(opts)
    local worldCtx       = opts.worldCtx
    local outer          = opts.outer
    local parentCanvas   = opts.parentCanvas
    local basePxPerCm    = opts.basePxPerCm
    local cellCm         = opts.cellCm or 100.0
    local gridOriginX    = opts.gridOriginX or 0.0
    local gridOriginY    = opts.gridOriginY or 0.0
    local colors         = opts.colors
    local getTierArrow   = opts.getTierArrowColor
    local getMachineCol  = opts.getMachineColor

    local krl = GetKRL()
    if not (Core.IsValidObj(krl) and Core.IsValidObj(worldCtx) and Core.IsValidObj(outer) and Core.IsValidObj(parentCanvas)) then
        return nil
    end

    local TILE_CM   = RT.TILE_WORLD_CM
    local TILE_PX   = RT.TILE_PX
    local PX_PER_CM = RT.PX_PER_CM
    local TILE_BASE_PX = TILE_CM * basePxPerCm
    local CELL_PX   = cellCm * PX_PER_CM
    local PORT_PX   = math.max(14.0, CELL_PX * 0.56)

    local tiles = {} -- "tx,ty" -> { tx, ty, key, minX, maxX, minY, maxY, rt, img, visible, dirty, platforms, walls, machines, links, ports }
    local dirtyList = {}
    local dirtySet = {}
    local destroyed = false

    local function tileKey(tx, ty) return tx .. "," .. ty end

    local function getOrCreateTile(tx, ty)
        local key = tileKey(tx, ty)
        local t = tiles[key]
        if t then return t end

        t = {
            tx = tx,
            ty = ty,
            key = key,
            minX = tx * TILE_CM,
            maxX = (tx + 1) * TILE_CM,
            minY = ty * TILE_CM,
            maxY = (ty + 1) * TILE_CM,
            rt = nil,
            img = nil,
            visible = true,
            dirty = false,
            platforms = {},
            walls = {},
            machines = {}, -- mAddr -> drawEntry
            links = {},    -- pKey -> linkEntry
            ports = {},    -- mAddr -> { { x, y }, ... }
        }
        tiles[key] = t
        return t
    end

    local function markTileDirty(t)
        if not t or t.dirty then return end
        t.dirty = true
        if not dirtySet[t.key] then
            dirtySet[t.key] = true
            dirtyList[#dirtyList + 1] = t
        end
    end

    local function ensureTileWidget(t)
        if Core.IsValidObj(t.rt) and Core.IsValidObj(t.img) then return true end
        local okRT, rt = CreateRT2D(krl, worldCtx, TILE_PX, TILE_PX)
        if not okRT or not Core.IsValidObj(rt) then return false end

        if not Core.IsValidObj(CachedImageCls) then
            CachedImageCls = Core.FindOrLoadClass("/Script/UMG.Image")
        end
        if not Core.IsValidObj(CachedImageCls) then return false end

        local okI, img = pcall(StaticConstructObject, CachedImageCls, outer)
        if not okI or not Core.IsValidObj(img) then return false end

        pcall(function()
            img:SetVisibility(t.visible and 3 or 1)
            if img.SetBrushResourceObject then
                img:SetBrushResourceObject(rt)
            end
            if img.SetColorAndOpacity then
                img:SetColorAndOpacity(COL_WHITE)
            end
            local slot = parentCanvas:AddChildToCanvas(img)
            if Core.IsValidObj(slot) then
                slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
                slot:SetAlignment({ X = 0.0, Y = 0.0 })
                slot:SetPosition({ X = t.tx * TILE_BASE_PX, Y = t.ty * TILE_BASE_PX })
                -- +0.5px overlap prevents subpixel hairlines between adjacent tiles when scaled
                slot:SetSize({ X = TILE_BASE_PX + 0.5, Y = TILE_BASE_PX + 0.5 })
                slot:SetZOrder(2)
            end
        end)

        t.rt = rt
        t.img = img
        return true
    end

    local function forEachOverlappingTile(minX, maxX, minY, maxY, createIfMissing, fn)
        local tMinX = math.floor(minX / TILE_CM)
        local tMaxX = math.floor(maxX / TILE_CM)
        local tMinY = math.floor(minY / TILE_CM)
        local tMaxY = math.floor(maxY / TILE_CM)
        for tx = tMinX, tMaxX do
            for ty = tMinY, tMaxY do
                local t = createIfMissing and getOrCreateTile(tx, ty) or tiles[tileKey(tx, ty)]
                if t then fn(t) end
            end
        end
    end

    local function drawTileNow(t)
        if destroyed or not t then return false end
        if not ensureTileWidget(t) then return false end

        pcall(function() krl:ClearRenderTarget2D(worldCtx, t.rt, COL_CLEAR) end)
        local canvas, ctx = BeginDrawRT(krl, worldCtx, t.rt)
        if not Core.IsValidObj(canvas) then return false end

        local whiteTex = GetWhiteTex()
        local fontObj = GetDrawFont()
        local ox, oy = t.minX, t.minY

        pcall(function()
            -- 1. Platforms
            for i = 1, #t.platforms do
                local p = t.platforms[i]
                local pcx = (p.cx - ox) * PX_PER_CM
                local pcy = (p.cy - oy) * PX_PER_CM
                local pw  = p.ex * 2.0 * PX_PER_CM
                local ph  = p.ey * 2.0 * PX_PER_CM
                DrawFilledRect(canvas, whiteTex, pcx, pcy, pw + 3.0, ph + 3.0, colors.PlatformBorder, 0.0)
                DrawFilledRect(canvas, whiteTex, pcx, pcy, pw, ph, colors.PlatformFill, 0.0)
            end

            -- 2. Grid lines (100cm minor, 400cm major)
            local minCol = math.ceil((t.minX - gridOriginX) / cellCm)
            local maxCol = math.floor((t.maxX - gridOriginX) / cellCm)
            for c = minCol, maxCol do
                local gx = ((gridOriginX + c * cellCm) - ox) * PX_PER_CM
                local isMaj = ((c % 4) == 0)
                DrawLine(canvas, gx, 0.0, gx, TILE_PX, isMaj and 1.4 or 0.9, isMaj and COL_GRID_MAJ or COL_GRID_MIN)
            end
            local minRow = math.ceil((t.minY - gridOriginY) / cellCm)
            local maxRow = math.floor((t.maxY - gridOriginY) / cellCm)
            for r = minRow, maxRow do
                local gy = ((gridOriginY + r * cellCm) - oy) * PX_PER_CM
                local isMaj = ((r % 4) == 0)
                DrawLine(canvas, 0.0, gy, TILE_PX, gy, isMaj and 1.4 or 0.9, isMaj and COL_GRID_MAJ or COL_GRID_MIN)
            end

            -- 3. Interior walls (2-pass border + fill so adjacent segments merge cleanly)
            local wallPad = 11.0 * (PX_PER_CM / basePxPerCm)
            for i = 1, #t.walls do
                local w = t.walls[i]
                local wx = (w.cx - ox) * PX_PER_CM
                local wy = (w.cy - oy) * PX_PER_CM
                local ww = math.max(2.0, w.w * PX_PER_CM)
                local wh = math.max(2.0, w.h * PX_PER_CM)
                DrawFilledRect(canvas, whiteTex, wx, wy, ww + wallPad, wh + wallPad, colors.WallBorder, 0.0)
            end
            for i = 1, #t.walls do
                local w = t.walls[i]
                local wx = (w.cx - ox) * PX_PER_CM
                local wy = (w.cy - oy) * PX_PER_CM
                local ww = math.max(2.0, w.w * PX_PER_CM)
                local wh = math.max(2.0, w.h * PX_PER_CM)
                DrawFilledRect(canvas, whiteTex, wx, wy, ww + 1.0, wh + 1.0, colors.WallFill, 0.0)
            end

            -- 4. Machines & Conveyors
            for _, m in pairs(t.machines) do
                local mx = (m.x - ox) * PX_PER_CM
                local my = (m.y - oy) * PX_PER_CM
                local pxW = math.max(8.0, m.rx * CELL_PX)
                local pxH = math.max(8.0, m.ry * CELL_PX)
                local fillW = math.max(6.0, pxW - 2.0)
                local fillH = math.max(6.0, pxH - 2.0)
                local sp = m.sprite

                if m.cat == "Conveyor" then
                    local tier = (sp and sp.tier) or 1
                    local td = (tier == 1) and 1.0 or ((tier == 2) and 0.78 or 0.62)
                    local bgCol = { R = 0.22 * td, G = 0.24 * td, B = 0.27 * td, A = 0.96 }
                    local railCol = { R = 0.05, G = 0.06, B = 0.08, A = 0.98 }
                    local arrowCol = getTierArrow(tier)
                    local norm = (math.floor((m.yaw or 0.0) / 90.0 + 0.5) % 4 + 4) % 4
                    local isVert = (norm == 1 or norm == 3)
                    local railThick = math.max(2.0, math.min(fillW, fillH) * 0.12)
                    local bedW = isVert and math.max(4.0, fillW - railThick * 2.0) or fillW
                    local bedH = isVert and fillH or math.max(4.0, fillH - railThick * 2.0)
                    DrawFilledRect(canvas, whiteTex, mx, my, fillW, fillH, railCol, 0.0)
                    DrawFilledRect(canvas, whiteTex, mx, my, bedW, bedH, bgCol, 0.0)
                    local armLen = math.max(6.0, math.min(pxW, pxH) * 0.30)
                    local armThick = math.max(1.8, math.min(2.8, math.min(pxW, pxH) * 0.065))
                    DrawChevron(canvas, whiteTex, mx, my, armLen, armThick, m.yaw or 0.0, arrowCol)
                else
                    local bgCol = (sp and sp.bgCol) or getMachineCol(m.cat)
                    local bdrCol = (sp and sp.borderCol) or { R = 0.08, G = 0.10, B = 0.14, A = 1.0 }
                    DrawFilledRect(canvas, whiteTex, mx, my, pxW, pxH, bdrCol, 0.0)
                    DrawFilledRect(canvas, whiteTex, mx, my, fillW, fillH, bgCol, 0.0)

                    local hasChips = m.overlayChips and #m.overlayChips > 0
                    if sp and Core.IsValidObj(sp.tex) then
                        local shiftUp = (hasChips and pxH >= 52.0)
                        local iconDim
                        if sp.fullTileTex then
                            iconDim = math.max(6.0, math.min(fillW, fillH))
                        else
                            local availH = shiftUp and (fillH * 0.56) or (fillH * 0.82)
                            iconDim = math.max(6.0, math.min(fillW * 0.82, availH))
                        end
                        local iconY = shiftUp and (my - fillH * 0.17) or my
                        local rot = (sp.directional and math.abs(m.yaw or 0.0) > 0.1) and m.yaw or 0.0
                        DrawSprite(canvas, sp.tex, mx, iconY, iconDim, iconDim, COL_WHITE, rot)
                    end

                    if m.clsLow and (m.clsLow:find("splitter", 1, true) or m.clsLow:find("balancer", 1, true)) then
                        DrawSplitterOrBalancerChevrons(canvas, whiteTex, mx, my, pxW, pxH, m.yaw or 0.0, m.clsLow)
                    elseif m.isUnderground then
                        local arrowCol = getTierArrow(sp and sp.tier or 1)
                        local armLen = math.max(6.0, math.min(pxW, pxH) * 0.34)
                        DrawChevron(canvas, whiteTex, mx, my, armLen, 2.4, m.yaw or 0.0, arrowCol)
                        if m.drawExitPair and m.pairX and m.pairY then
                            local omx = (m.pairX - ox) * PX_PER_CM
                            local omy = (m.pairY - oy) * PX_PER_CM
                            DrawFilledRect(canvas, whiteTex, omx, omy, pxW, pxH, bdrCol, 0.0)
                            DrawFilledRect(canvas, whiteTex, omx, omy, fillW, fillH, bgCol, 0.0)
                            if sp and Core.IsValidObj(sp.tex) then
                                local rot = (sp.directional and math.abs(m.yaw or 0.0) > 0.1) and m.yaw or 0.0
                                DrawSprite(canvas, sp.tex, omx, omy, math.min(fillW, fillH) * 0.82, math.min(fillW, fillH) * 0.82, COL_WHITE, rot)
                            end
                            DrawChevron(canvas, whiteTex, omx, omy, armLen, 2.4, m.yaw or 0.0, arrowCol)
                        end
                    end

                    -- Bottom item/rate chip overlay (pure UCanvas — zero Blueprint UserWidgets!)
                    if hasChips then
                        local chips = m.overlayChips
                        local nChips = #chips
                        local iconSz = Core.Clamp(math.min(pxW * (nChips > 1 and 0.34 or 0.48), pxH * 0.35), 14.0, 30.0)
                        local colW = m.isProducer and math.max(42.0, iconSz + 18.0) or (iconSz + 8.0)
                        local badgeW = nChips * colW + (nChips > 1 and 4.0 or 0.0)
                        local badgeH = m.isProducer and (iconSz + 16.0) or (iconSz + 6.0)
                        local badgeY = (pxH >= 52.0) and (my + pxH * 0.24) or my
                        DrawFilledRect(canvas, whiteTex, mx, badgeY, badgeW, badgeH, COL_CHIP_BG, 0.0)

                        local startX = mx - badgeW * 0.5 + colW * 0.5
                        for ci = 1, nChips do
                            local chip = chips[ci]
                            local cx = startX + (ci - 1) * (colW + 4.0)
                            local itemTex = GetItemTexture(chip.item)
                            local iconCY = (chip.rate ~= nil) and (badgeY - 6.0) or badgeY
                            if Core.IsValidObj(itemTex) then
                                DrawSprite(canvas, itemTex, cx, iconCY, iconSz, iconSz, COL_WHITE, 0.0)
                            end
                            if chip.rate ~= nil and Core.IsValidObj(fontObj) then
                                local rateStr = (chip.rate >= 10.0) and string.format("%.0f/m", chip.rate) or string.format("%.1f/m", chip.rate)
                                canvas:K2_DrawText(
                                    fontObj, rateStr,
                                    { X = cx, Y = badgeY + badgeH * 0.5 - 7.0 },
                                    { X = 0.62, Y = 0.62 },
                                    COL_WHITE, 0.0, COL_SHADOW, { X = 1.0, Y = 1.0 },
                                    true, true, true, COL_OUTLINE
                                )
                            end
                        end
                    end
                end
            end

            -- 5. Underground belt dashed link lines
            for _, lk in pairs(t.links) do
                local x1 = (lk.x1 - ox) * PX_PER_CM
                local y1 = (lk.y1 - oy) * PX_PER_CM
                local x2 = (lk.x2 - ox) * PX_PER_CM
                local y2 = (lk.y2 - oy) * PX_PER_CM
                DrawDashedLine(canvas, x1, y1, x2, y2, lk.lineCol, 2.6, 10.0, 6.0)
                local linkAng = math.deg(math.atan(y2 - y1, x2 - x1))
                DrawChevron(canvas, whiteTex, (x1 + x2) * 0.5, (y1 + y2) * 0.5, 11.0, 2.4, linkAng, lk.arrowCol)
            end

            -- 6. Item port badges
            local innerSz = math.max(6.0, PORT_PX - 4.0)
            for _, plist in pairs(t.ports) do
                for i = 1, #plist do
                    local p = plist[i]
                    local px = (p.x - ox) * PX_PER_CM
                    local py = (p.y - oy) * PX_PER_CM
                    DrawFilledRect(canvas, whiteTex, px, py, PORT_PX, PORT_PX, COL_PORT_OUT, 0.0)
                    DrawFilledRect(canvas, whiteTex, px, py, innerSz, innerSz, COL_PORT_IN, 0.0)
                end
            end
        end)

        EndDrawRT(krl, worldCtx, ctx)
        t.dirty = false
        return true
    end

    local inst = {}

    function inst.AddPlatform(cx, cy, ex, ey)
        local p = { cx = cx, cy = cy, ex = ex, ey = ey }
        forEachOverlappingTile(cx - ex - 20.0, cx + ex + 20.0, cy - ey - 20.0, cy + ey + 20.0, true, function(t)
            t.platforms[#t.platforms + 1] = p
            markTileDirty(t)
        end)
    end

    function inst.AddWall(cx, cy, w, h)
        local wObj = { cx = cx, cy = cy, w = w, h = h }
        local hw, hh = w * 0.5 + 30.0, h * 0.5 + 30.0
        forEachOverlappingTile(cx - hw, cx + hw, cy - hh, cy + hh, true, function(t)
            t.walls[#t.walls + 1] = wObj
            markTileDirty(t)
        end)
    end

    function inst.UpsertMachine(mAddr, drawEntry, portList)
        -- Remove old tiles if updating
        inst.RemoveMachine(mAddr)
        local hw = drawEntry.rx * cellCm * 0.5 + 40.0
        local hh = drawEntry.ry * cellCm * 0.5 + 40.0
        local minX, maxX = drawEntry.x - hw, drawEntry.x + hw
        local minY, maxY = drawEntry.y - hh, drawEntry.y + hh
        if drawEntry.drawExitPair and drawEntry.pairX and drawEntry.pairY then
            minX = math.min(minX, drawEntry.pairX - hw)
            maxX = math.max(maxX, drawEntry.pairX + hw)
            minY = math.min(minY, drawEntry.pairY - hh)
            maxY = math.max(maxY, drawEntry.pairY + hh)
        end
        local touched = {}
        forEachOverlappingTile(minX, maxX, minY, maxY, true, function(t)
            t.machines[mAddr] = drawEntry
            if portList and #portList > 0 then
                t.ports[mAddr] = portList
            end
            touched[#touched + 1] = t
            markTileDirty(t)
        end)
        drawEntry._rtTiles = touched
    end

    function inst.AddUndergroundLink(pKey, linkEntry)
        local minX = math.min(linkEntry.x1, linkEntry.x2) - 40.0
        local maxX = math.max(linkEntry.x1, linkEntry.x2) + 40.0
        local minY = math.min(linkEntry.y1, linkEntry.y2) - 40.0
        local maxY = math.max(linkEntry.y1, linkEntry.y2) + 40.0
        local touched = {}
        forEachOverlappingTile(minX, maxX, minY, maxY, true, function(t)
            t.links[pKey] = linkEntry
            touched[#touched + 1] = t
            markTileDirty(t)
        end)
        linkEntry._rtTiles = touched
    end

    function inst.RemoveUndergroundLink(pKey, linkEntry)
        if not linkEntry or not linkEntry._rtTiles then return end
        for i = 1, #linkEntry._rtTiles do
            local t = linkEntry._rtTiles[i]
            if t.links[pKey] then
                t.links[pKey] = nil
                markTileDirty(t)
            end
        end
    end

    function inst.RemoveMachine(mAddr)
        for _, t in pairs(tiles) do
            local changed = false
            if t.machines[mAddr] then t.machines[mAddr] = nil; changed = true end
            if t.ports[mAddr] then t.ports[mAddr] = nil; changed = true end
            if changed then markTileDirty(t) end
        end
    end

    function inst.UpdateViewport(vMinX, vMaxX, vMinY, vMaxY)
        for _, t in pairs(tiles) do
            local inView = (t.maxX >= vMinX and t.minX <= vMaxX and t.maxY >= vMinY and t.minY <= vMaxY)
            if t.visible ~= inView then
                t.visible = inView
                if Core.IsValidObj(t.img) then
                    pcall(function() t.img:SetVisibility(inView and 3 or 1) end)
                end
            end
        end
    end

    -- Draws dirty tiles prioritizing currently visible tiles first (maxTiles per call)
    function inst.PumpDirtyTiles(maxTiles, budgetSec)
        if destroyed or #dirtyList == 0 then return false end
        local limit = maxTiles or 2
        local budgetEnd = os.clock() + (budgetSec or 0.008)
        local drawn = 0

        -- Pass 1: visible dirty tiles first
        local nextDirty = {}
        for i = 1, #dirtyList do
            local t = dirtyList[i]
            if t.dirty then
                if t.visible and (drawn < 1 or (drawn < limit and os.clock() < budgetEnd)) then
                    dirtySet[t.key] = nil
                    drawTileNow(t)
                    drawn = drawn + 1
                else
                    nextDirty[#nextDirty + 1] = t
                end
            else
                dirtySet[t.key] = nil
            end
        end

        -- Pass 2: off-screen dirty tiles if budget remains
        if drawn < limit and os.clock() < budgetEnd and #nextDirty > 0 then
            local rem = {}
            for i = 1, #nextDirty do
                local t = nextDirty[i]
                if t.dirty and drawn < limit and os.clock() < budgetEnd then
                    dirtySet[t.key] = nil
                    drawTileNow(t)
                    drawn = drawn + 1
                elseif t.dirty then
                    rem[#rem + 1] = t
                end
            end
            nextDirty = rem
        end

        dirtyList = nextDirty
        return #dirtyList > 0
    end

    function inst.HasDirtyTiles()
        return #dirtyList > 0
    end

    function inst.GetTileCount()
        local n = 0
        for _ in pairs(tiles) do n = n + 1 end
        return n
    end

    function inst.Destroy()
        destroyed = true
        for _, t in pairs(tiles) do
            if Core.IsValidObj(t.img) then
                pcall(function() t.img:RemoveFromParent() end)
            end
            t.rt = nil
            t.img = nil
        end
        tiles = {}
        dirtyList = {}
        dirtySet = {}
    end

    return inst
end

return RT
