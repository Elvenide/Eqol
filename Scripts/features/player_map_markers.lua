-- Eqol Feature: World Map Player Markers & Nametags
-- Renders exact player positions and nametags on WBP_SolarSystemMap_C.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "PlayerMapMarkers",
}

local PATHS = {
    WBPTextClass = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    BorderClass  = "/Script/UMG.Border",
}

local MapMarkerPools = {} -- mapAddr -> { { Dot, Label }, ... }
local PollActive = false

local function RefreshWorldMapPlayers(solarMap)
    if not Core.IsValidObj(solarMap) then return end
    local okVis, vis = pcall(function() return solarMap:IsVisible() end)
    if not okVis or not vis then return end

    local panningCanvas = solarMap.WBP_PanningCanvas
    if not Core.IsValidObj(panningCanvas) then return end

    local canvas = nil
    pcall(function() canvas = panningCanvas.Canvas or panningCanvas.ContentCanvas end)
    if not Core.IsValidObj(canvas) then return end

    local mapAddr = solarMap:GetAddress()
    MapMarkerPools[mapAddr] = MapMarkerPools[mapAddr] or {}
    local pool = MapMarkerPools[mapAddr]

    local pc = Core.GetLocalPlayerController()
    local outer = Core.GetWidgetOuter(solarMap)
    local players = StationData.GetAllPlayersInfo(pc)

    local scale = 1.0
    pcall(function()
        if type(solarMap.Scale) == "number" and solarMap.Scale > 0 then
            scale = solarMap.Scale
        end
    end)

    local count = 0
    for _, p in ipairs(players) do
        if p.HasPos then
            count = count + 1
            local entry = pool[count]
            if not entry or not Core.IsValidObj(entry.Dot) then
                local dot = Core.CreateRawWidget(PATHS.BorderClass, outer)
                local lbl = Core.CreateUserWidget(PATHS.WBPTextClass, solarMap, pc)
                if Core.IsValidObj(dot) and Core.IsValidObj(lbl) then
                    pcall(function() lbl:SetSize(11) end)
                    local dSlot = canvas:AddChildToCanvas(dot)
                    local lSlot = canvas:AddChildToCanvas(lbl)
                    if Core.IsValidObj(dSlot) then pcall(function() dSlot:SetZOrder(90) end) end
                    if Core.IsValidObj(lSlot) then pcall(function() lSlot:SetZOrder(91) end) end
                    entry = { Dot = dot, DotSlot = dSlot, Label = lbl, LabelSlot = lSlot }
                    pool[count] = entry
                end
            end

            if entry and Core.IsValidObj(entry.Dot) then
                -- Convert world cm to map canvas units (sector-relative)
                local mx = p.X * scale * 0.0001
                local my = p.Y * scale * 0.0001
                local col = p.IsLocal and { R = 0.35, G = 0.92, B = 0.55, A = 1.0 }
                    or (p.IsOnline and { R = 0.25, G = 0.78, B = 0.95, A = 1.0 } or { R = 0.65, G = 0.28, B = 0.28, A = 0.9 })
                pcall(function()
                    entry.Dot:SetBrushColor(col)
                    entry.Dot:SetVisibility(0)
                    entry.DotSlot:SetPosition({ X = mx, Y = my })
                    entry.DotSlot:SetSize({ X = 10.0, Y = 10.0 })
                    entry.DotSlot:SetAlignment({ X = 0.5, Y = 0.5 })
                    entry.Label:SetText(Core.MakeText(p.Name))
                    entry.Label:SetVisibility(0)
                    entry.LabelSlot:SetPosition({ X = mx, Y = my - 14.0 })
                    entry.LabelSlot:SetAlignment({ X = 0.5, Y = 1.0 })
                end)
            end
        end
    end

    for i = count + 1, #pool do
        if Core.IsValidObj(pool[i].Dot) then pcall(function() pool[i].Dot:SetVisibility(1) end) end
        if Core.IsValidObj(pool[i].Label) then pcall(function() pool[i].Label:SetVisibility(1) end) end
    end
end

local function StartPoll()
    if PollActive then return end
    PollActive = true
    local function Tick()
        local ok, maps = pcall(FindAllOf, "WBP_SolarSystemMap_C")
        if ok and maps then
            for _, m in ipairs(maps) do
                if Core.IsValidObj(m) then
                    pcall(RefreshWorldMapPlayers, m)
                end
            end
        end
        ExecuteInGameThreadWithDelay(200, Tick)
    end
    ExecuteInGameThreadWithDelay(200, Tick)
end

Feature.WatchWidgets = {
    WBP_SolarSystemMap_C = function(m)
        RefreshWorldMapPlayers(m)
    end,
}

function Feature.Init()
    StartPoll()
end

function Feature.PruneCaches()
    for addr, pool in pairs(MapMarkerPools) do
        if not pool[1] or not Core.IsValidObj(pool[1].Dot) then
            MapMarkerPools[addr] = nil
        end
    end
end

return Feature
