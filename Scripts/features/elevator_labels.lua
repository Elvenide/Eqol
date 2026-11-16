-- Eqol Feature: Item Elevator Port Labels
-- Displays floating item icons and names above nearby item elevator ports showing what items are in each port.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "ElevatorLabels",
}

local PATHS = {
    WBPTextClass       = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass       = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    CanvasPanelClass   = "/Script/UMG.CanvasPanel",
    BorderClass        = "/Script/UMG.Border",
    HorizontalBoxClass = "/Script/UMG.HorizontalBox",
}

local MAX_DISPLAY_DIST_SQ = 2500.0 * 2500.0
local COLORS = {
    Bg = { R = 0.025, G = 0.038, B = 0.055, A = 0.82 },
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
            slot:SetHorizontalAlignment(0)
            slot:SetVerticalAlignment(0)
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

local function GetOrCreateLabelWidget(st, idx)
    local entry = st.Pool[idx]
    if entry and Core.IsValidObj(entry.Root) then
        return entry
    end

    local bg = Core.CreateRawWidget(PATHS.BorderClass, st.Outer)
    local hBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, st.Outer)
    local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, st.Hud, st.PC)
    local lblTxt = Core.CreateUserWidget(PATHS.WBPTextClass, st.Hud, st.PC)

    if not (Core.IsValidObj(bg) and Core.IsValidObj(hBox) and Core.IsValidObj(itemW) and Core.IsValidObj(lblTxt)) then
        return nil
    end

    pcall(function()
        bg:SetBrushColor(COLORS.Bg)
        bg:SetPadding({ Left = 6.0, Top = 3.0, Right = 8.0, Bottom = 3.0 })
        itemW:SetIconSize(18.0)
        lblTxt:SetSize(11)
    end)

    local iSlot = hBox:AddChildToHorizontalBox(itemW)
    if Core.IsValidObj(iSlot) then
        pcall(function()
            iSlot:SetVerticalAlignment(2)
            iSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 6.0, Bottom = 0.0 })
        end)
    end

    local tSlot = hBox:AddChildToHorizontalBox(lblTxt)
    if Core.IsValidObj(tSlot) then
        pcall(function() tSlot:SetVerticalAlignment(2) end)
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
        ItemWidget = itemW,
        LabelText = lblTxt,
        Slot = cSlot,
    }
    st.Pool[idx] = entry
    return entry
end

local function ExtractItemFromElevator(elev)
    if not Core.IsValidObj(elev) then return nil, nil end

    for _, prop in ipairs({ "CurrentItem", "PortItem", "Item", "FilterItem" }) do
        local ok, v = pcall(function() return elev[prop] end)
        if ok and v ~= nil then
            if Core.IsValidObj(v) and v.DisplayName ~= nil then
                return v, nil
            end
            local okI, it = pcall(function() return v.Item end)
            if okI and Core.IsValidObj(it) then
                return it, tonumber(v.Amount)
            end
        end
    end

    local inv = StationData.GetContainerInventory(elev)
    if Core.IsValidObj(inv) then
        local foundItem, foundAmt = nil, nil
        local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
        if okSlots and slots then
            StationData.ForEachArray(slots, function(_, elem)
                if foundItem then return end
                local st = elem
                if type(elem.get) == "function" then
                    local okG, g = pcall(function() return elem:get() end)
                    if okG then st = g end
                end
                if st and Core.IsValidObj(st.Item) and (tonumber(st.Amount) or 0) > 0 then
                    foundItem = st.Item
                    foundAmt = tonumber(st.Amount)
                end
            end)
        end
        if foundItem then return foundItem, foundAmt end
    end

    return nil, nil
end

local function UpdateElevatorLabels()
    local layoutLib = Core.GetCDO(Core.PATHS.WidgetLayoutLibCDO)
    if not Core.IsValidObj(layoutLib) then return end

    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local px, py, pz = 0, 0, 0
    local pawn = pc.Pawn
    if Core.IsValidObj(pawn) then
        local okL, loc = pcall(function() return pawn:K2_GetActorLocation() end)
        if okL and loc then
            px, py, pz = loc.X or 0, loc.Y or 0, loc.Z or 0
        end
    end

    local okElevs, elevators = pcall(FindAllOf, "ItemElevatorObject")
    if not okElevs or not elevators then return end

    local visiblePorts = {}
    for _, elev in ipairs(elevators) do
        if Core.IsValidObj(elev) then
            local item, amt = ExtractItemFromElevator(elev)
            if Core.IsValidObj(item) then
                local ex, ey, ez = StationData.GetMachineWorldPosAndYaw(elev, nil)
                local dx, dy, dz = ex - px, ey - py, ez - pz
                if (dx * dx + dy * dy + dz * dz) <= MAX_DISPLAY_DIST_SQ then
                    local itemName = "Item"
                    pcall(function() itemName = item.DisplayName:ToString() end)
                    local labelStr = amt and string.format("%s x%d", itemName, amt) or itemName
                    table.insert(visiblePorts, {
                        Item = item,
                        Label = labelStr,
                        X = ex,
                        Y = ey,
                        Z = ez + 95.0,
                    })
                end
            end
        end
    end

    local okHuds, huds = pcall(FindAllOf, "WBP_CharacterHUD_C")
    if not okHuds or not huds then return end

    for _, hud in ipairs(huds) do
        if Core.IsValidObj(hud) then
            local st = EnsureOverlayOnHud(hud)
            if st then
                local okVis, hudVis = pcall(function() return hud:IsVisible() end)
                local count = 0

                if okVis and hudVis and not pc.bShowMouseCursor then
                    for _, port in ipairs(visiblePorts) do
                        local screenPos = {}
                        local okProj, projected = pcall(function()
                            return layoutLib:ProjectWorldLocationToWidgetPosition(
                                pc,
                                { X = port.X, Y = port.Y, Z = port.Z },
                                screenPos,
                                false
                            )
                        end)
                        if okProj and projected and screenPos.X and screenPos.Y then
                            count = count + 1
                            local lbl = GetOrCreateLabelWidget(st, count)
                            if lbl then
                                pcall(function()
                                    lbl.ItemWidget:SetItem(port.Item)
                                    lbl.LabelText:SetText(Core.MakeText(port.Label))
                                    lbl.Slot:SetPosition({ X = screenPos.X, Y = screenPos.Y })
                                    lbl.Root:SetVisibility(0)
                                end)
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
        pcall(UpdateElevatorLabels)
        ExecuteInGameThreadWithDelay(66, Tick)
    end
    ExecuteInGameThreadWithDelay(66, Tick)
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
