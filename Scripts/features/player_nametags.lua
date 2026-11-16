-- Eqol Feature: Player Nametags with Online/Offline Status
-- Displays floating nametags above all players (including the local player)
-- with a green (Online) or red/grey (Offline) status indicator.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "PlayerNametags",
}

local PATHS = {
    WBPTextClass       = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    CanvasPanelClass   = "/Script/UMG.CanvasPanel",
    BorderClass        = "/Script/UMG.Border",
    HorizontalBoxClass = "/Script/UMG.HorizontalBox",
    SizeBoxClass       = "/Script/UMG.SizeBox",
}

local COLORS = {
    Bg      = { R = 0.025, G = 0.038, B = 0.055, A = 0.78 },
    Online  = { R = 0.05402, G = 0.7042, B = 0.05281, A = 1.0 },
    Offline = { R = 0.55, G = 0.22, B = 0.22, A = 0.90 },
}

local HudOverlays = {} -- hudAddr -> { Hud, PC, Outer, Canvas, Pool = {} }
local PollActive = false

local function EnsureOverlayOnHud(hud)
    if not Core.IsValidObj(hud) then return nil end
    local addr = hud:GetAddress()
    local st = HudOverlays[addr]
    if st and Core.IsValidObj(st.Canvas) then
        return st
    end

    local mainOverlay = hud.MainOverlay
    if not Core.IsValidObj(mainOverlay) then return nil end

    local outer = Core.GetWidgetOuter(hud)
    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local canvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    if not Core.IsValidObj(canvas) then return nil end

    local slot = mainOverlay:AddChildToOverlay(canvas)
    if Core.IsValidObj(slot) then
        pcall(function()
            slot:SetHorizontalAlignment(0) -- Fill
            slot:SetVerticalAlignment(0)   -- Fill
        end)
    end

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

local function GetOrCreateTagWidget(st, idx)
    local entry = st.Pool[idx]
    if entry and Core.IsValidObj(entry.Root) then
        return entry
    end

    local bg = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
    local hBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, st.Outer)
    local dotBox = Core.CreateRawWidget(PATHS.SizeBoxClass, st.Outer)
    local dot = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
    local nameTxt = Core.CreateUserWidget(PATHS.WBPTextClass, st.Hud, st.PC)

    if not (Core.IsValidObj(bg) and Core.IsValidObj(hBox) and Core.IsValidObj(dotBox) and Core.IsValidObj(dot) and Core.IsValidObj(nameTxt)) then
        return nil
    end

    pcall(function()
        bg:SetBrushColor(COLORS.Bg)
        bg:SetPadding({ Left = 7.0, Top = 3.0, Right = 8.0, Bottom = 3.0 })
        dotBox:SetWidthOverride(8.0)
        dotBox:SetHeightOverride(8.0)
        nameTxt:SetSize(12)
    end)

    dotBox:AddChild(dot)
    local dSlot = hBox:AddChildToHorizontalBox(dotBox)
    if Core.IsValidObj(dSlot) then
        pcall(function()
            dSlot:SetVerticalAlignment(2)
            dSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 6.0, Bottom = 0.0 })
        end)
    end

    local nSlot = hBox:AddChildToHorizontalBox(nameTxt)
    if Core.IsValidObj(nSlot) then
        pcall(function() nSlot:SetVerticalAlignment(2) end)
    end

    bg:AddChild(hBox)
    local cSlot = st.Canvas:AddChildToCanvas(bg)
    if Core.IsValidObj(cSlot) then
        pcall(function()
            cSlot:SetAutoSize(true)
            cSlot:SetAlignment({ X = 0.5, Y = 1.0 })
        end)
    end

    entry = {
        Root = bg,
        Dot = dot,
        NameText = nameTxt,
        Slot = cSlot,
    }
    st.Pool[idx] = entry
    return entry
end

local function UpdateNametags()
    local layoutLib = Core.GetCDO(Core.PATHS.WidgetLayoutLibCDO)
    if not Core.IsValidObj(layoutLib) then return end

    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local players = StationData.GetAllPlayersInfo(pc)

    local okHuds, huds = pcall(FindAllOf, "WBP_CharacterHUD_C")
    if not okHuds or not huds then return end

    for _, hud in ipairs(huds) do
        if Core.IsValidObj(hud) then
            local st = EnsureOverlayOnHud(hud)
            if st then
                local okVis, hudVis = pcall(function() return hud:IsVisible() end)
                local count = 0

                if okVis and hudVis then
                    for _, p in ipairs(players) do
                        if p.HasPos and not Core.IsValidObj(p.PilotedShip) then
                            local screenPos = {}
                            local okProj, projected = pcall(function()
                                return layoutLib:ProjectWorldLocationToWidgetPosition(
                                    pc,
                                    { X = p.X, Y = p.Y, Z = p.Z + 115.0 },
                                    screenPos,
                                    false
                                )
                            end)
                            if okProj and projected and screenPos.X and screenPos.Y then
                                count = count + 1
                                local tag = GetOrCreateTagWidget(st, count)
                                if tag then
                                    local statusStr = p.IsOnline and "Online" or "Offline"
                                    local dotCol = p.IsOnline and COLORS.Online or COLORS.Offline
                                    pcall(function()
                                        tag.Dot:SetBrushColor(dotCol)
                                        tag.NameText:SetText(Core.MakeText(string.format("%s (%s)", p.Name, statusStr)))
                                        tag.Slot:SetPosition({ X = screenPos.X, Y = screenPos.Y })
                                        tag.Root:SetVisibility(0)
                                    end)
                                end
                            end
                        end
                    end
                end

                for i = count + 1, #st.Pool do
                    if Core.IsValidObj(st.Pool[i].Root) then
                        pcall(function() st.Pool[i].Root:SetVisibility(1) end)
                    end
                end
            end
        end
    end
end

local function StartPoll()
    if PollActive then return end
    PollActive = true

    local function Tick()
        pcall(UpdateNametags)
        ExecuteInGameThreadWithDelay(33, Tick)
    end
    ExecuteInGameThreadWithDelay(33, Tick)
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        EnsureOverlayOnHud(hud)
    end,
}

function Feature.Init()
    StartPoll()
end

function Feature.PruneCaches()
    for addr, st in pairs(HudOverlays) do
        if not Core.IsValidObj(st.Canvas) then
            HudOverlays[addr] = nil
        end
    end
end

return Feature
