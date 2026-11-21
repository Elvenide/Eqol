-- Eqol Feature: World Map Player Markers & Nametags
-- Renders exact player positions and nametags on WBP_SolarSystemMap_C using
-- event-driven hooks (no background FindAllOf polling to avoid GC races on map close).

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "PlayerMapMarkers",
    DisplayName = "World Map Player Markers",
    Description = "Shows player positions and nametags on the Solar System / Sector map.",
}

local PATHS = {
    WBPTextClass     = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    CanvasPanelClass = "/Script/UMG.CanvasPanel",
    BorderClass      = "/Script/UMG.Border",
}

local MapOverlays = {} -- mapAddr -> { SolarMap, PanningCanvas, Outer, Canvas, Pool, IsSectorMap }
local CachedUMGClasses = {}

local function CreateRawFast(classPath, outer)
    if not Core.IsValidObj(outer) then return nil end
    local cls = CachedUMGClasses[classPath]
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(classPath)
        if Core.IsValidObj(cls) then CachedUMGClasses[classPath] = cls end
    end
    if not Core.IsValidObj(cls) then return nil end
    local ok, w = pcall(StaticConstructObject, cls, outer)
    return (ok and Core.IsValidObj(w)) and w or nil
end

local function EnsureMapOverlay(solarMap)
    if not Core.IsValidObj(solarMap) then return nil end
    local addr = solarMap:GetAddress()
    local st = MapOverlays[addr]
    if st and Core.IsValidObj(st.Canvas) then
        return st
    end

    -- Opportunistically prune stale overlays on insert
    for k, old in pairs(MapOverlays) do
        if not old or not Core.IsValidObj(old.SolarMap) or not Core.IsValidObj(old.Canvas) then
            MapOverlays[k] = nil
        end
    end

    local panningCanvas = solarMap.WBP_PanningCanvas
    if not Core.IsValidObj(panningCanvas) then return nil end
    local overlay = panningCanvas.Overlay_0
    if not Core.IsValidObj(overlay) then return nil end

    local outer = Core.GetWidgetOuter(panningCanvas)
    local canvas = CreateRawFast(PATHS.CanvasPanelClass, outer)
    if not Core.IsValidObj(canvas) then return nil end

    local slot = overlay:AddChildToOverlay(canvas)
    if Core.IsValidObj(slot) then
        pcall(function()
            slot:SetHorizontalAlignment(0) -- Fill
            slot:SetVerticalAlignment(0)   -- Fill
        end)
    end

    st = {
        SolarMap = solarMap,
        PanningCanvas = panningCanvas,
        Outer = outer,
        Canvas = canvas,
        Pool = {},
        IsSectorMap = false,
    }
    MapOverlays[addr] = st
    return st
end

local function GetMapSolarSystemID(solarMap)
    if not Core.IsValidObj(solarMap) then return nil end
    local sysId = nil
    pcall(function()
        local ss = solarMap.SolarSystem or solarMap.CurrentSolarSystem or solarMap.ViewedSolarSystem
        if Core.IsValidObj(ss) then
            sysId = StationData.GetObjectKey(ss) or tostring(ss:GetAddress())
        else
            local rawId = solarMap.SolarSystemID or solarMap.CurrentSolarSystemID
            if rawId ~= nil then sysId = tostring(rawId) end
        end
    end)
    return sysId
end

local function HideAllMarkers(st)
    if not st or not st.Pool then return end
    for i = 1, #st.Pool do
        local entry = st.Pool[i]
        if entry then
            if Core.IsValidObj(entry.Dot) then pcall(function() entry.Dot:SetVisibility(1) end) end
            if Core.IsValidObj(entry.Label) then pcall(function() entry.Label:SetVisibility(1) end) end
        end
    end
end

local function RefreshWorldMapPlayers(solarMap, modeOverride)
    if not Core.IsValidObj(solarMap) then return end
    local okVis, vis = pcall(function() return solarMap:IsVisible() end)
    if not okVis or not vis then return end

    local st = EnsureMapOverlay(solarMap)
    if not st then return end

    if modeOverride == "sector" then
        st.IsSectorMap = true
    elseif modeOverride == "system" then
        st.IsSectorMap = false
    end

    -- Never plot system-space player coordinates onto the galaxy/sector map
    if st.IsSectorMap then
        HideAllMarkers(st)
        return
    end

    local pc = Core.GetLocalPlayerController()
    local players = StationData.GetAllPlayersInfo(pc)
    local mapSysId = GetMapSolarSystemID(solarMap)

    local scale = 1.0
    local panX, panY = 0.0, 0.0
    pcall(function()
        if type(solarMap.Scale) == "number" and solarMap.Scale > 0 then
            scale = solarMap.Scale
        end
        if st.PanningCanvas.CurrentOffset then
            panX = tonumber(st.PanningCanvas.CurrentOffset.X) or 0.0
            panY = tonumber(st.PanningCanvas.CurrentOffset.Y) or 0.0
        end
    end)

    local count = 0
    for _, p in ipairs(players) do
        local sameSystem = (mapSysId == nil) or (p.SolarSystemID == nil) or (p.SolarSystemID == mapSysId)
        if p.HasPos and sameSystem then
            count = count + 1
            local entry = st.Pool[count]
            if not entry or not Core.IsValidObj(entry.Dot) then
                local dot = CreateRawFast(PATHS.BorderClass, st.Outer)
                local lbl = Core.CreateUserWidget(PATHS.WBPTextClass, solarMap, pc)
                if Core.IsValidObj(dot) and Core.IsValidObj(lbl) then
                    pcall(function() lbl:SetSize(11) end)
                    local dSlot = st.Canvas:AddChildToCanvas(dot)
                    local lSlot = st.Canvas:AddChildToCanvas(lbl)
                    if Core.IsValidObj(dSlot) then pcall(function() dSlot:SetZOrder(90) end) end
                    if Core.IsValidObj(lSlot) then pcall(function() lSlot:SetZOrder(91) end) end
                    entry = { Dot = dot, DotSlot = dSlot, Label = lbl, LabelSlot = lSlot, LastName = nil }
                    st.Pool[count] = entry
                end
            end

            if entry and Core.IsValidObj(entry.Dot) then
                local mx = panX + p.X * scale * 0.0001
                local my = panY + p.Y * scale * 0.0001
                local col = p.IsLocal and { R = 0.35, G = 0.92, B = 0.55, A = 1.0 }
                    or (p.IsOnline and { R = 0.25, G = 0.78, B = 0.95, A = 1.0 } or { R = 0.65, G = 0.28, B = 0.28, A = 0.9 })
                pcall(function()
                    entry.Dot:SetBrushColor(col)
                    entry.Dot:SetVisibility(0)
                    entry.DotSlot:SetPosition({ X = mx, Y = my })
                    entry.DotSlot:SetSize({ X = 10.0, Y = 10.0 })
                    entry.DotSlot:SetAlignment({ X = 0.5, Y = 0.5 })
                    if entry.LastName ~= p.Name then
                        entry.Label:SetText(Core.MakeText(p.Name))
                        entry.LastName = p.Name
                    end
                    entry.Label:SetVisibility(0)
                    entry.LabelSlot:SetPosition({ X = mx, Y = my - 14.0 })
                    entry.LabelSlot:SetAlignment({ X = 0.5, Y = 1.0 })
                end)
            end
        end
    end

    for i = count + 1, #st.Pool do
        if Core.IsValidObj(st.Pool[i].Dot) then pcall(function() st.Pool[i].Dot:SetVisibility(1) end) end
        if Core.IsValidObj(st.Pool[i].Label) then pcall(function() st.Pool[i].Label:SetVisibility(1) end) end
    end
end

Feature.WatchWidgets = {
    WBP_SolarSystemMap_C = function(m)
        if Core.IsFeatureEnabled("PlayerMapMarkers") then
            RefreshWorldMapPlayers(m)
        end
    end,
}

function Feature.OnToggle(enabled)
    if not enabled then
        for _, st in pairs(MapOverlays) do
            HideAllMarkers(st)
        end
    else
        for _, st in pairs(MapOverlays) do
            if st and Core.IsValidObj(st.SolarMap) then
                pcall(RefreshWorldMapPlayers, st.SolarMap)
            end
        end
    end
end

function Feature.RegisterHooks()
    local hooks = {
        { fn = "GenerateSystemMap", mode = "system" },
        { fn = "GenerateSectorMap", mode = "sector" },
        { fn = "SetScale", mode = nil },
        { fn = "BndEvt__WBP_SolarSystemMap_WBP_PanningCanvas_K2Node_ComponentBoundEvent_0_OnOffsetChanged__DelegateSignature", mode = nil },
    }
    for _, h in ipairs(hooks) do
        local modeOverride = h.mode
        Core.TryRegisterHook(
            "SolarSystemMap_" .. h.fn,
            "/Game/Blueprints/Widgets/HUDs/Map/WBP_SolarSystemMap.WBP_SolarSystemMap_C:" .. h.fn,
            function(Context)
                if not Core.IsFeatureEnabled("PlayerMapMarkers") then return end
                local m = Context:get()
                if Core.IsValidObj(m) then
                    pcall(RefreshWorldMapPlayers, m, modeOverride)
                end
            end
        )
    end
end

function Feature.PruneCaches()
    MapOverlays = {}
    CachedUMGClasses = {}
end

return Feature
