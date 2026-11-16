-- Eqol Feature: 2D Station Minimap HUD
-- Bottom-left HUD minimap visible only while on foot inside a space station.
-- Displays the current floor at a 5x5 station-module scale, centered on the player,
-- with clickable item icons on assemblers, refineries, and containers (no conveyors).

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "StationMinimap",
}

local PATHS = {
    WBPBorderClass    = "/Game/Blueprints/Widgets/Basic/WBP_Border.WBP_Border_C",
    WBPButtonClass    = "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C",
    WBPTextClass      = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass      = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    CanvasPanelClass  = "/Script/UMG.CanvasPanel",
    BorderClass       = "/Script/UMG.Border",
    ButtonClass       = "/Script/UMG.Button",
    SizeBoxClass      = "/Script/UMG.SizeBox",
    OverlayClass      = "/Script/UMG.Overlay",
    ImageClass        = "/Script/UMG.Image",
}

local MINIMAP_SIZE = 240.0
local MODULES_SPAN = 5.0
local PX_PER_MODULE = MINIMAP_SIZE / MODULES_SPAN -- 48 px per 1x1 module
local POLL_INTERVAL_MS = 150

-- Game-matched HUD colors
local COLORS = {
    PanelBg      = { R = 0.025, G = 0.038, B = 0.055, A = 0.78 },
    ModuleFill   = { R = 0.075, G = 0.115, B = 0.160, A = 0.90 },
    ModuleBorder = { R = 0.190, G = 0.340, B = 0.440, A = 0.85 },
    Assembler    = { R = 0.150, G = 0.620, B = 0.820, A = 0.92 },
    Container    = { R = 0.850, G = 0.600, B = 0.120, A = 0.92 },
    Conveyor     = { R = 0.300, G = 0.360, B = 0.420, A = 0.65 },
    OtherMachine = { R = 0.240, G = 0.300, B = 0.380, A = 0.80 },
    PlayerDot    = { R = 0.350, G = 0.920, B = 0.550, A = 1.00 },
    Transparent  = { R = 0.0,   G = 0.0,   B = 0.0,   A = 0.0  },
}

local HudStates = {} -- hudAddr -> { Root, Canvas, FloorLabel, PlatformPool, MachinePool, IconPool, PlayerDot }
local PollActive = false
local HookedIconButtons = {}

--------------------------------------------------------------------------------
-- UI Construction Helpers
--------------------------------------------------------------------------------

local function SetCanvasSlot(slot, x, y, w, h, alignX, alignY)
    if not Core.IsValidObj(slot) then return end
    pcall(function()
        slot:SetPosition({ X = x, Y = y })
        slot:SetSize({ X = w, Y = h })
        slot:SetAlignment({ X = alignX or 0.5, Y = alignY or 0.5 })
    end)
end

local function EnsureMinimapOnHud(hud)
    if not Core.IsValidObj(hud) then return nil end

    local addr = hud:GetAddress()
    local st = HudStates[addr]
    if st and Core.IsValidObj(st.Root) then
        return st
    end

    local mainOverlay = hud.MainOverlay
    if not Core.IsValidObj(mainOverlay) then
        return nil
    end

    local outer = Core.GetWidgetOuter(hud)
    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    -- Outer SizeBox anchored bottom-left
    local rootBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local frameBorder = Core.CreateUserWidget(PATHS.WBPBorderClass, hud, pc)
    local bgBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local innerOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    local canvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local floorText = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)

    if not (Core.IsValidObj(rootBox) and Core.IsValidObj(bgBorder) and Core.IsValidObj(innerOverlay) and Core.IsValidObj(canvas)) then
        return nil
    end

    pcall(function()
        rootBox:SetWidthOverride(MINIMAP_SIZE + 8.0)
        rootBox:SetHeightOverride(MINIMAP_SIZE + 8.0)
        bgBorder:SetBrushColor(COLORS.PanelBg)
        bgBorder:SetPadding({ Left = 2.0, Top = 2.0, Right = 2.0, Bottom = 2.0 })
        canvas:SetClipping(1) -- ClipToBounds
    end)

    -- Build hierarchy: rootBox -> (frameBorder or bgBorder) -> innerOverlay -> (canvas + floorText)
    innerOverlay:AddChild(canvas)
    local canvasSlot = canvas.Slot
    if Core.IsValidObj(canvasSlot) then
        pcall(function()
            canvasSlot:SetHorizontalAlignment(0) -- Fill
            canvasSlot:SetVerticalAlignment(0)   -- Fill
        end)
    end

    if Core.IsValidObj(floorText) then
        pcall(function()
            floorText:SetSize(11)
            floorText:SetText(Core.MakeText("F1"))
        end)
        local fSlot = innerOverlay:AddChild(floorText)
        if Core.IsValidObj(fSlot) then
            pcall(function()
                fSlot:SetHorizontalAlignment(3) -- Right
                fSlot:SetVerticalAlignment(1)   -- Top
                fSlot:SetPadding({ Left = 0.0, Top = 4.0, Right = 6.0, Bottom = 0.0 })
            end)
        end
    end

    bgBorder:AddChild(innerOverlay)
    if Core.IsValidObj(frameBorder) and frameBorder.SetContentForSlot then
        local okSlot = pcall(function() frameBorder:SetContentForSlot(FName("Content"), bgBorder) end)
        if okSlot then
            rootBox:AddChild(frameBorder)
        else
            rootBox:AddChild(bgBorder)
        end
    else
        rootBox:AddChild(bgBorder)
    end

    -- Player marker in center of minimap
    local playerDot = Core.CreateRawWidget(PATHS.BorderClass, outer)
    if Core.IsValidObj(playerDot) then
        pcall(function() playerDot:SetBrushColor(COLORS.PlayerDot) end)
        local pSlot = canvas:AddChildToCanvas(playerDot)
        SetCanvasSlot(pSlot, MINIMAP_SIZE * 0.5, MINIMAP_SIZE * 0.5, 8.0, 8.0, 0.5, 0.5)
        pcall(function() pSlot:SetZOrder(50) end)
    end

    -- Attach rootBox to WBP_CharacterHUD.MainOverlay (Bottom-Left)
    local mainSlot = mainOverlay:AddChildToOverlay(rootBox)
    if Core.IsValidObj(mainSlot) then
        pcall(function()
            mainSlot:SetHorizontalAlignment(1) -- HAlign_Left
            mainSlot:SetVerticalAlignment(3)   -- VAlign_Bottom
            mainSlot:SetPadding({ Left = 24.0, Top = 0.0, Right = 0.0, Bottom = 24.0 })
        end)
    end

    -- Start collapsed until verified inside a station
    pcall(function() rootBox:SetVisibility(1) end) -- Collapsed

    st = {
        Hud = hud,
        PC = pc,
        Outer = outer,
        Root = rootBox,
        Canvas = canvas,
        FloorText = floorText,
        PlayerDot = playerDot,
        PlatformPool = {},
        MachinePool = {},
        IconPool = {},
    }
    HudStates[addr] = st
    return st
end

local function HidePoolFrom(pool, startIdx)
    for i = startIdx, #pool do
        local entry = pool[i]
        if entry and Core.IsValidObj(entry.Widget) then
            pcall(function() entry.Widget:SetVisibility(1) end) -- Collapsed
        end
    end
end

local function GetOrCreatePlatformWidget(st, index)
    local entry = st.PlatformPool[index]
    if entry and Core.IsValidObj(entry.Widget) then
        return entry
    end

    -- Outer border = module boundary outline, inner border = dark module floor fill
    local outerB = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
    local innerB = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
    if not Core.IsValidObj(outerB) or not Core.IsValidObj(innerB) then return nil end

    pcall(function()
        outerB:SetBrushColor(COLORS.ModuleBorder)
        outerB:SetPadding({ Left = 2.0, Top = 2.0, Right = 2.0, Bottom = 2.0 })
        innerB:SetBrushColor(COLORS.ModuleFill)
    end)
    outerB:AddChild(innerB)

    local slot = st.Canvas:AddChildToCanvas(outerB)
    if Core.IsValidObj(slot) then
        pcall(function() slot:SetZOrder(1) end)
    end

    entry = { Widget = outerB, Slot = slot }
    st.PlatformPool[index] = entry
    return entry
end

local function GetOrCreateConnectorWidget(st, index)
    st.ConnectorPool = st.ConnectorPool or {}
    local entry = st.ConnectorPool[index]
    if entry and Core.IsValidObj(entry.Widget) then
        return entry
    end

    local b = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
    if not Core.IsValidObj(b) then return nil end

    local slot = st.Canvas:AddChildToCanvas(b)
    if Core.IsValidObj(slot) then
        pcall(function() slot:SetZOrder(5) end)
    end

    entry = { Widget = b, Slot = slot }
    st.ConnectorPool[index] = entry
    return entry
end

local function GetOrCreateMachineWidget(st, index)
    local entry = st.MachinePool[index]
    if entry and Core.IsValidObj(entry.Widget) then
        return entry
    end

    local b = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
    if not Core.IsValidObj(b) then return nil end

    local slot = st.Canvas:AddChildToCanvas(b)
    if Core.IsValidObj(slot) then
        pcall(function() slot:SetZOrder(10) end)
    end

    entry = { Widget = b, Slot = slot }
    st.MachinePool[index] = entry
    return entry
end

local function GetOrCreateIconWidget(st, index)
    local entry = st.IconPool[index]
    if entry and Core.IsValidObj(entry.Widget) then
        return entry
    end

    local btn = Core.CreateUserWidget(PATHS.WBPButtonClass, st.Hud, st.PC)
    local img = Core.CreateRawWidget(PATHS.ImageClass, st.Outer)
    if not Core.IsValidObj(btn) or not Core.IsValidObj(img) then
        return nil
    end

    pcall(function()
        btn:SetBackgroundColour(COLORS.Transparent)
        btn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        btn:SetContentForSlot(FName("Content"), img)
    end)

    local slot = st.Canvas:AddChildToCanvas(btn)
    if Core.IsValidObj(slot) then
        pcall(function() slot:SetZOrder(25) end)
    end

    entry = {
        Widget = btn,
        ImageWidget = img,
        Slot = slot,
        Machine = nil,
    }

    Core.RegisterWBPButtonClick(btn, function()
        if Core.IsValidObj(entry.Machine) then
            StationData.ToggleMachineIcon(entry.Machine)
        end
    end)

    st.IconPool[index] = entry
    return entry
end

local function WorldDeltaToMinimap(dx, dy, cosH, sinH, scale, halfMap)
    local fwd = dx * cosH + dy * sinH
    local right = -dx * sinH + dy * cosH
    return halfMap + right * scale, halfMap - fwd * scale
end

--------------------------------------------------------------------------------
-- Minimap Refresh
--------------------------------------------------------------------------------

local function UpdateMinimapState(st)
    if not st or not Core.IsValidObj(st.Root) or not Core.IsValidObj(st.Hud) then
        return
    end

    -- Hide if HUD itself is not visible
    local okVis, hudVis = pcall(function() return st.Hud:IsVisible() end)
    if not okVis or not hudVis then
        pcall(function() st.Root:SetVisibility(1) end)
        return
    end

    local pc = Core.GetLocalPlayerController()
    local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
    if not inStation or not Core.IsValidObj(walkFrame) then
        pcall(function() st.Root:SetVisibility(1) end) -- Collapsed when in ship / space
        return
    end

    pcall(function() st.Root:SetVisibility(0) end) -- Visible

    -- Player world coordinates & facing yaw (so top of minimap = player walking direction)
    local px, py, pz, playerYaw = 0, 0, 0, 0
    local pawn = pc.Pawn
    if Core.IsValidObj(pawn) then
        local okLoc, loc = pcall(function() return pawn:K2_GetActorLocation() end)
        if okLoc and loc then
            px = tonumber(loc.X) or 0
            py = tonumber(loc.Y) or 0
            pz = tonumber(loc.Z) or 0
        end
        local okRot, rot = pcall(function() return pc:GetControlRotation() end)
        if okRot and rot and type(rot.Yaw) == "number" then
            playerYaw = rot.Yaw
        else
            local okPR, pRot = pcall(function() return pawn:K2_GetActorRotation() end)
            if okPR and pRot and type(pRot.Yaw) == "number" then
                playerYaw = pRot.Yaw
            end
        end
    else
        local b = StationData.GetPlatformWorldBounds(walkFrame)
        px, py, pz = b.cx, b.cy, b.cz
    end

    local hRad = math.rad(playerYaw)
    local cosH = math.cos(hRad)
    local sinH = math.sin(hRad)

    local floors, curFloorIdx, unitSize = StationData.BuildStationFloorMap(station, walkFrame, pz)
    local curFloor = floors[curFloorIdx]
    if not curFloor then
        HidePoolFrom(st.PlatformPool, 1)
        HidePoolFrom(st.MachinePool, 1)
        HidePoolFrom(st.IconPool, 1)
        return
    end

    if Core.IsValidObj(st.FloorText) then
        pcall(function() st.FloorText:SetText(Core.MakeText(string.format("F%d", curFloorIdx))) end)
    end

    local scale = PX_PER_MODULE / unitSize
    local halfMap = MINIMAP_SIZE * 0.5
    local maxCullDist = (MODULES_SPAN * 0.5 + 2.0) * unitSize

    local platCount = 0
    local connCount = 0
    local machCount = 0
    local iconCount = 0

    for _, pe in ipairs(curFloor.platforms) do
        local b = pe.bounds
        local dx = b.cx - px
        local dy = b.cy - py
        if math.abs(dx) <= maxCullDist and math.abs(dy) <= maxCullDist then
            platCount = platCount + 1
            local pEntry = GetOrCreatePlatformWidget(st, platCount)
            if pEntry then
                local sx, sy = WorldDeltaToMinimap(dx, dy, cosH, sinH, scale, halfMap)
                local pw = math.max(12.0, b.ex * 2.0 * scale - 2.0)
                local ph = math.max(12.0, b.ey * 2.0 * scale - 2.0)
                SetCanvasSlot(pEntry.Slot, sx, sy, pw, ph, 0.5, 0.5)
                pcall(function()
                    pEntry.Widget:SetRenderTransformAngle((b.yaw or 0) - playerYaw)
                    pEntry.Widget:SetVisibility(0)
                end)
            end

            -- Entry points / connectors on this module
            local conns = StationData.GetPlatformConnectors(pe.platform)
            for _, c in ipairs(conns) do
                connCount = connCount + 1
                local cEntry = GetOrCreateConnectorWidget(st, connCount)
                if cEntry then
                    local csx, csy = WorldDeltaToMinimap(c.x - px, c.y - py, cosH, sinH, scale, halfMap)
                    local cCol = c.occupied and { R = 0.25, G = 0.78, B = 0.92, A = 0.95 } or { R = 0.90, G = 0.72, B = 0.18, A = 0.90 }
                    pcall(function()
                        cEntry.Widget:SetBrushColor(cCol)
                        cEntry.Widget:SetRenderTransformAngle((b.yaw or 0) - playerYaw)
                        cEntry.Widget:SetVisibility(0)
                    end)
                    SetCanvasSlot(cEntry.Slot, csx, csy, 8.0, 8.0, 0.5, 0.5)
                end
            end

            -- Machines on this platform
            local machines = StationData.GetFrameMachines(pe.platform)
            for _, m in ipairs(machines) do
                local mx, my, _, myaw = StationData.GetMachineWorldPosAndYaw(m, b)
                local mdx = mx - px
                local mdy = my - py
                if math.abs(mdx) <= maxCullDist and math.abs(mdy) <= maxCullDist then
                    local cat = StationData.GetMachineCategory(m)
                    local msx, msy = WorldDeltaToMinimap(mdx, mdy, cosH, sinH, scale, halfMap)

                    machCount = machCount + 1
                    local mEntry = GetOrCreateMachineWidget(st, machCount)
                    if mEntry then
                        local col = COLORS.OtherMachine
                        local mw, mh = 10.0, 10.0
                        if cat == "Assembler" then
                            col = COLORS.Assembler
                            mw, mh = 14.0, 14.0
                        elseif cat == "Container" then
                            col = COLORS.Container
                            mw, mh = 12.0, 12.0
                        elseif cat == "Conveyor" then
                            col = COLORS.Conveyor
                            mw, mh = 6.0, 6.0
                        end
                        pcall(function()
                            mEntry.Widget:SetBrushColor(col)
                            mEntry.Widget:SetRenderTransformAngle((myaw or 0) - playerYaw)
                            mEntry.Widget:SetVisibility(0)
                        end)
                        SetCanvasSlot(mEntry.Slot, msx, msy, mw, mh, 0.5, 0.5)
                    end

                    -- Item icon on Assembler/Refinery and Container (NOT Conveyor on minimap)
                    if (cat == "Assembler" or cat == "Container") and not StationData.IsMachineIconHidden(m) then
                        local item = StationData.GetPrimaryItemForMachine(m)
                        if Core.IsValidObj(item) then
                            local tex = StationData.GetItemIconTexture(item)
                            if Core.IsValidObj(tex) then
                                iconCount = iconCount + 1
                                local iEntry = GetOrCreateIconWidget(st, iconCount)
                                if iEntry then
                                    iEntry.Machine = m
                                    pcall(function()
                                        iEntry.ImageWidget:SetBrushFromTexture(tex, false)
                                        iEntry.Widget:SetVisibility(0)
                                    end)
                                    SetCanvasSlot(iEntry.Slot, msx, msy, 18.0, 18.0, 0.5, 0.5)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    HidePoolFrom(st.PlatformPool, platCount + 1)
    if st.ConnectorPool then HidePoolFrom(st.ConnectorPool, connCount + 1) end
    HidePoolFrom(st.MachinePool, machCount + 1)
    HidePoolFrom(st.IconPool, iconCount + 1)

    -- Render all players on this floor (with nametags)
    st.PlayerPool = st.PlayerPool or {}
    local pCount = 0
    local allPlayers = StationData.GetAllPlayersInfo(pc)
    for _, p in ipairs(allPlayers) do
        if p.HasPos and math.abs(p.Z - curFloor.z) <= 250.0 then
            local pdx = p.X - px
            local pdy = p.Y - py
            if math.abs(pdx) <= maxCullDist and math.abs(pdy) <= maxCullDist then
                pCount = pCount + 1
                local entry = st.PlayerPool[pCount]
                if not entry or not Core.IsValidObj(entry.Dot) then
                    local dot = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
                    local lbl = Core.CreateUserWidget(PATHS.WBPTextClass, st.Hud, st.PC)
                    if Core.IsValidObj(dot) and Core.IsValidObj(lbl) then
                        pcall(function() lbl:SetSize(10) end)
                        local dSlot = st.Canvas:AddChildToCanvas(dot)
                        local lSlot = st.Canvas:AddChildToCanvas(lbl)
                        if Core.IsValidObj(dSlot) then pcall(function() dSlot:SetZOrder(48) end) end
                        if Core.IsValidObj(lSlot) then pcall(function() lSlot:SetZOrder(49) end) end
                        entry = { Dot = dot, DotSlot = dSlot, Label = lbl, LabelSlot = lSlot }
                        st.PlayerPool[pCount] = entry
                    end
                end
                if entry and Core.IsValidObj(entry.Dot) then
                    local sx, sy = WorldDeltaToMinimap(pdx, pdy, cosH, sinH, scale, halfMap)
                    local col = p.IsLocal and COLORS.PlayerDot or (p.IsOnline and { R = 0.25, G = 0.85, B = 0.35, A = 1.0 } or { R = 0.60, G = 0.25, B = 0.25, A = 0.90 })
                    pcall(function()
                        entry.Dot:SetBrushColor(col)
                        entry.Dot:SetVisibility(0)
                        entry.Label:SetText(Core.MakeText(p.Name))
                        entry.Label:SetVisibility(0)
                    end)
                    SetCanvasSlot(entry.DotSlot, sx, sy, 8.0, 8.0, 0.5, 0.5)
                    SetCanvasSlot(entry.LabelSlot, sx, sy - 10.0, 100.0, 16.0, 0.5, 1.0)
                end
            end
        end
    end
    for i = pCount + 1, #st.PlayerPool do
        local e = st.PlayerPool[i]
        if e then
            if Core.IsValidObj(e.Dot) then pcall(function() e.Dot:SetVisibility(1) end) end
            if Core.IsValidObj(e.Label) then pcall(function() e.Label:SetVisibility(1) end) end
        end
    end
end

local function RefreshAllMinimapHuds()
    local anyValid = false
    for addr, st in pairs(HudStates) do
        if Core.IsValidObj(st.Hud) and Core.IsValidObj(st.Root) then
            anyValid = true
            UpdateMinimapState(st)
        else
            HudStates[addr] = nil
        end
    end

    if not anyValid then
        local ok, huds = pcall(FindAllOf, "WBP_CharacterHUD_C")
        if ok and huds then
            for _, hud in ipairs(huds) do
                if Core.IsValidObj(hud) then
                    local st = EnsureMinimapOnHud(hud)
                    if st then
                        UpdateMinimapState(st)
                    end
                end
            end
        end
    end
end

local function StartMinimapPoll()
    if PollActive then return end
    PollActive = true

    local function Tick()
        pcall(RefreshAllMinimapHuds)
        ExecuteInGameThreadWithDelay(POLL_INTERVAL_MS, Tick)
    end

    ExecuteInGameThreadWithDelay(POLL_INTERVAL_MS, Tick)
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        local st = EnsureMinimapOnHud(hud)
        if st then
            UpdateMinimapState(st)
        end
    end,
}

function Feature.Init()
    StationData.OnIconVisibilityChanged(function()
        pcall(RefreshAllMinimapHuds)
    end)
    StartMinimapPoll()
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "CharacterHUD_SetPiloting_Minimap",
        "/Game/Blueprints/Widgets/HUDs/WBP_CharacterHUD.WBP_CharacterHUD_C:SetPiloting",
        function(Context)
            local hud = Context:get()
            if Core.IsValidObj(hud) then
                local st = EnsureMinimapOnHud(hud)
                if st then UpdateMinimapState(st) end
            end
        end
    )

    Core.TryRegisterHook(
        "CharacterHUD_SetHUDHidden_Minimap",
        "/Game/Blueprints/Widgets/HUDs/WBP_CharacterHUD.WBP_CharacterHUD_C:SetHUDHidden",
        function(Context)
            local hud = Context:get()
            if Core.IsValidObj(hud) then
                local st = EnsureMinimapOnHud(hud)
                if st then UpdateMinimapState(st) end
            end
        end
    )
end

function Feature.PruneCaches()
    for addr, st in pairs(HudStates) do
        if not Core.IsValidObj(st.Root) then
            HudStates[addr] = nil
        end
    end
end

return Feature
