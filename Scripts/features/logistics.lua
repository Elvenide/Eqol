-- Eqol Feature: Logistics UI Screen
-- 1. Configurable keybind (default L, configurable in Settings -> Controls) + bottom-right HUD indicator.
-- 2. Icon-heavy Logistics UI showing:
--    - All items currently stored in containers on the station (inventory-like icon grid)
--    - Every production machine (assemblers, refineries, etc.), its output rate (items/min),
--      individual ingredient consumption rates (items/min), and a bottleneck indicator.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "Logistics",
}

local DEFAULT_KEY = "L"
local MAPPING_NAME = "Eqol_Logistics"

local PATHS = {
    WindowBaseClass    = "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C",
    WBPBorderClass     = "/Game/Blueprints/Widgets/Basic/WBP_Border.WBP_Border_C",
    WBPButtonClass     = "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C",
    WBPTextClass       = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass       = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    InventorySlotClass = "/Game/Blueprints/Widgets/Display/Inventory/WBP_InventorySlot.WBP_InventorySlot_C",
    InputRemapClass    = "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C",
    InputKeyClass      = "/Game/Blueprints/Widgets/Display/WBP_InputKey.WBP_InputKey_C",
    BorderClass        = "/Script/UMG.Border",
    SizeBoxClass       = "/Script/UMG.SizeBox",
    VerticalBoxClass   = "/Script/UMG.VerticalBox",
    HorizontalBoxClass = "/Script/UMG.HorizontalBox",
    ScrollBoxClass     = "/Script/UMG.ScrollBox",
    WrapBoxClass       = "/Script/UMG.WrapBox",
}

local STATUS_COLORS = {
    Green = { R = 0.05402, G = 0.7042, B = 0.05281, A = 1.0 },
    Amber = { R = 0.8917,  G = 0.6242, B = 0.0,     A = 1.0 },
    Red   = { R = 0.5177,  G = 0.0,    B = 0.04122, A = 1.0 },
    RowBg = { R = 0.030,   G = 0.045,  B = 0.065,   A = 0.85 },
    KeyBg = { R = 0.060,   G = 0.090,  B = 0.130,   A = 0.85 },
}

local UE_TO_UE4SS_KEY = {
    BackSpace         = Key and Key.BACKSPACE,
    Tab               = Key and Key.TAB,
    Enter             = Key and Key.RETURN,
    Return            = Key and Key.RETURN,
    SpaceBar          = Key and Key.SPACE,
    Left              = Key and Key.LEFT_ARROW,
    Up                = Key and Key.UP_ARROW,
    Right             = Key and Key.RIGHT_ARROW,
    Down              = Key and Key.DOWN_ARROW,
    Zero              = Key and Key.ZERO,
    One               = Key and Key.ONE,
    Two               = Key and Key.TWO,
    Three             = Key and Key.THREE,
    Four              = Key and Key.FOUR,
    Five              = Key and Key.FIVE,
    Six               = Key and Key.SIX,
    Seven             = Key and Key.SEVEN,
    Eight             = Key and Key.EIGHT,
    Nine              = Key and Key.NINE,
    Semicolon         = Key and Key.OEM_ONE,
    Equals            = Key and Key.OEM_PLUS,
    Comma             = Key and Key.OEM_COMMA,
    Hyphen            = Key and Key.OEM_MINUS,
    Period            = Key and Key.OEM_PERIOD,
    Slash             = Key and Key.OEM_TWO,
    Tilde             = Key and Key.OEM_THREE,
    LeftBracket       = Key and Key.OEM_FOUR,
    Backslash         = Key and Key.OEM_FIVE,
    RightBracket      = Key and Key.OEM_SIX,
    Apostrophe        = Key and Key.OEM_SEVEN,
}

local ActiveUe4ssKey = nil
local RegisteredKeyHandlers = {}
local FallbackPollActive = false
local FallbackWasDown = false

local InjectedSettingsRows = {}
local TrackedRemapRows = {}
local HudKeyIndicators = {} -- hudAddr -> { Root, KeyText }
local ActiveLogisticsWin = nil
local HookedButtons = {}

--------------------------------------------------------------------------------
-- Keybind Helpers
--------------------------------------------------------------------------------

local function MakeInputChord(keyName)
    local resolvedName = (keyName and keyName ~= "") and keyName or "None"
    return {
        Key = { KeyName = FName(resolvedName) },
        bShift = false,
        bCtrl = false,
        bAlt = false,
        bCmd = false,
    }
end

local function ResolveUE4SSKey(keyName)
    if not keyName or keyName == "" or keyName == "None" or not Key then
        return nil
    end
    if UE_TO_UE4SS_KEY[keyName] then
        return UE_TO_UE4SS_KEY[keyName]
    end
    local upper = string.upper(keyName)
    if Key[upper] then
        return Key[upper]
    end
    return nil
end

local function IsSelectingAnyKeybind()
    for addr, row in pairs(TrackedRemapRows) do
        if Core.IsValidObj(row) then
            local sel = row.InputKeySelector
            if Core.IsValidObj(sel) then
                local okSel, selecting = pcall(function() return sel:GetIsSelectingKey() end)
                if okSel and selecting then
                    return true
                end
            end
        else
            TrackedRemapRows[addr] = nil
        end
    end
    return false
end

local function UpdateAllHudKeyIndicators()
    local keyStr = tostring(Core.Config.LogisticsKey or DEFAULT_KEY)
    if keyStr == "None" or keyStr == "" then
        keyStr = "-"
    end
    for addr, entry in pairs(HudKeyIndicators) do
        if Core.IsValidObj(entry.Root) and Core.IsValidObj(entry.KeyText) then
            pcall(function() entry.KeyText:SetText(Core.MakeText(keyStr)) end)
        else
            HudKeyIndicators[addr] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Logistics Data Aggregation
--------------------------------------------------------------------------------

local function CollectStationLogisticsData(station, walkFrame)
    local platforms = StationData.GetStationPlatforms(station)
    if #platforms == 0 and Core.IsValidObj(walkFrame) then
        platforms = { walkFrame }
    end

    local containerItems = {} -- itemKey -> { Item = uobj, Amount = number }
    local assemblers = {}
    local stationProdRates = {} -- itemKey -> items/min
    local stationConsRates = {} -- itemKey -> items/min

    local seenMachines = {}

    for _, plat in ipairs(platforms) do
        local machines = StationData.GetFrameMachines(plat)
        for _, m in ipairs(machines) do
            local mAddr = m:GetAddress()
            if not seenMachines[mAddr] then
                seenMachines[mAddr] = true
                local cat = StationData.GetMachineCategory(m)

                if cat == "Container" then
                    local inv = StationData.GetContainerInventory(m)
                    if Core.IsValidObj(inv) then
                        local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
                        if okSlots and slots then
                            StationData.ForEachArray(slots, function(_, elem)
                                local st = elem
                                if type(elem.get) == "function" then
                                    local okG, g = pcall(function() return elem:get() end)
                                    if okG then st = g end
                                end
                                if st and Core.IsValidObj(st.Item) then
                                    local amt = tonumber(st.Amount) or 0
                                    if amt > 0 then
                                        local k = StationData.GetObjectKey(st.Item) or tostring(st.Item:GetAddress())
                                        if not containerItems[k] then
                                            containerItems[k] = { Item = st.Item, Amount = 0 }
                                        end
                                        containerItems[k].Amount = containerItems[k].Amount + amt
                                    end
                                end
                            end)
                        end
                    end
                elseif cat == "Assembler" then
                    local rec = nil
                    pcall(function() rec = m.Recipe end)

                    local bonusMult = 1.0
                    pcall(function()
                        local bm = Core.GetFPFloat(m.BonusMultiplier)
                        if bm > 0.0001 then bonusMult = bm end
                    end)

                    local craftSec = 1.0
                    local inputs = {}
                    local outputs = {}

                    if Core.IsValidObj(rec) then
                        local okSec, sec = pcall(function() return rec:GetCraftingSeconds() end)
                        if okSec and type(sec) == "number" and sec > 0.0001 then
                            craftSec = sec
                        end

                        -- Outputs
                        local okOut, outStack = pcall(function() return rec.Output end)
                        if okOut and outStack and Core.IsValidObj(outStack.Item) then
                            local amt = tonumber(outStack.Amount) or 1
                            local rate = (amt * 60.0 / craftSec) * bonusMult
                            table.insert(outputs, { Item = outStack.Item, Rate = rate })
                            local k = StationData.GetObjectKey(outStack.Item) or tostring(outStack.Item:GetAddress())
                            stationProdRates[k] = (stationProdRates[k] or 0.0) + rate
                        else
                            local okOuts, outs = pcall(function() return rec:GetOutputs() end)
                            if okOuts and outs then
                                StationData.ForEachArray(outs, function(_, elem)
                                    local st = elem
                                    if type(elem.get) == "function" then
                                        local okG, g = pcall(function() return elem:get() end)
                                        if okG then st = g end
                                    end
                                    if st and Core.IsValidObj(st.Item) then
                                        local amt = tonumber(st.Amount) or 1
                                        local rate = (amt * 60.0 / craftSec) * bonusMult
                                        table.insert(outputs, { Item = st.Item, Rate = rate })
                                        local k = StationData.GetObjectKey(st.Item) or tostring(st.Item:GetAddress())
                                        stationProdRates[k] = (stationProdRates[k] or 0.0) + rate
                                    end
                                end)
                            end
                        end

                        -- Inputs
                        local okIn, inArr = pcall(function() return rec.Inputs end)
                        if okIn and inArr then
                            StationData.ForEachArray(inArr, function(_, elem)
                                local st = elem
                                if type(elem.get) == "function" then
                                    local okG, g = pcall(function() return elem:get() end)
                                    if okG then st = g end
                                end
                                if st and Core.IsValidObj(st.Item) then
                                    local amt = tonumber(st.Amount) or 1
                                    local rate = (amt * 60.0 / craftSec) * bonusMult
                                    table.insert(inputs, { Item = st.Item, Rate = rate })
                                    local k = StationData.GetObjectKey(st.Item) or tostring(st.Item:GetAddress())
                                    stationConsRates[k] = (stationConsRates[k] or 0.0) + rate
                                end
                            end)
                        end
                    end

                    table.insert(assemblers, {
                        Machine = m,
                        Name = StationData.GetMachineDisplayName(m),
                        HasRecipe = Core.IsValidObj(rec),
                        Inputs = inputs,
                        Outputs = outputs,
                    })
                end
            end
        end
    end

    -- Sort container items by descending amount
    local sortedItems = {}
    for _, entry in pairs(containerItems) do
        table.insert(sortedItems, entry)
    end
    table.sort(sortedItems, function(a, b) return a.Amount > b.Amount end)

    return sortedItems, assemblers, stationProdRates, stationConsRates
end

--------------------------------------------------------------------------------
-- Logistics Window UI
--------------------------------------------------------------------------------

local function CloseLogisticsWindow()
    if Core.IsValidObj(ActiveLogisticsWin) then
        pcall(function() ActiveLogisticsWin:RemoveFromParent() end)
    end
    ActiveLogisticsWin = nil
end

local function FormatRate(rate)
    if rate >= 100.0 then
        return string.format("%.0f/m", rate)
    elseif rate >= 10.0 then
        return string.format("%.1f/m", rate)
    end
    return string.format("%.2f/m", rate)
end

local function AddItemRateChip(parentHBox, window, pc, outer, item, rate, tintColor)
    local chipBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, window, pc)
    local rateTxt = Core.CreateUserWidget(PATHS.WBPTextClass, window, pc)
    if not (Core.IsValidObj(chipBox) and Core.IsValidObj(itemW) and Core.IsValidObj(rateTxt)) then
        return
    end

    pcall(function()
        itemW:SetIconSize(24.0)
        itemW:SetItem(item)
        rateTxt:SetSize(12)
        rateTxt:SetText(Core.MakeText(FormatRate(rate)))
        if tintColor and rateTxt.SetColour then
            rateTxt:SetColour(tintColor)
        end
    end)

    local s1 = chipBox:AddChildToHorizontalBox(itemW)
    if Core.IsValidObj(s1) then
        pcall(function() s1:SetVerticalAlignment(2) end)
    end
    local s2 = chipBox:AddChildToHorizontalBox(rateTxt)
    if Core.IsValidObj(s2) then
        pcall(function()
            s2:SetVerticalAlignment(2)
            s2:SetPadding({ Left = 4.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        end)
    end

    local pSlot = parentHBox:AddChildToHorizontalBox(chipBox)
    if Core.IsValidObj(pSlot) then
        pcall(function()
            pSlot:SetVerticalAlignment(2)
            pSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 12.0, Bottom = 0.0 })
        end)
    end
end

local function OpenLogisticsWindow()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
    if not inStation and not Core.IsValidObj(station) then
        Core.Log("Logistics: player is not in a station")
        return
    end

    local win = Core.CreateUserWidget(PATHS.WindowBaseClass, pc, pc)
    if not Core.IsValidObj(win) then
        Core.Log("Logistics: failed to construct WBP_WindowBase_C")
        return
    end

    ActiveLogisticsWin = win
    local outer = Core.GetWidgetOuter(win)

    pcall(function()
        win:SetWindowName(Core.MakeText("Logistics"))
        win:AddToViewport(50)
    end)

    if Core.IsValidObj(win.WBP_WindowHeader) and Core.IsValidObj(win.WBP_WindowHeader.CloseButton) then
        local closeBtn = win.WBP_WindowHeader.CloseButton
        local inner = closeBtn.Button or closeBtn
        local addr = inner:GetAddress()
        if not HookedButtons[addr] then
            HookedButtons[addr] = true
            pcall(function() inner.OnPressed:Add(CloseLogisticsWindow) end)
        end
    end

    local items, assemblers, prodRates, consRates = CollectStationLogisticsData(station, walkFrame)

    local rootBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local mainHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    if not (Core.IsValidObj(rootBox) and Core.IsValidObj(mainHBox)) then return end

    pcall(function() win:SetContentForSlot(FName("Content"), rootBox) end)

    -- Left Column: Container Inventory Grid (Icon-heavy)
    local leftVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local invHeader = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
    local invScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local invWrap = Core.CreateRawWidget(PATHS.WrapBoxClass, outer)

    if Core.IsValidObj(invHeader) then
        pcall(function()
            invHeader:SetSize(14)
            invHeader:SetText(Core.MakeText(string.format("Storage (%d)", #items)))
        end)
        leftVBox:AddChildToVerticalBox(invHeader)
    end

    if Core.IsValidObj(invWrap) and Core.IsValidObj(invScroll) then
        pcall(function()
            invWrap:SetInnerSlotPadding({ X = 4.0, Y = 4.0 })
        end)
        for _, entry in ipairs(items) do
            local slotW = Core.CreateUserWidget(PATHS.InventorySlotClass, win, pc)
            if Core.IsValidObj(slotW) then
                pcall(function()
                    slotW:SetItemStack({ Item = entry.Item, Amount = entry.Amount })
                end)
                invWrap:AddChildToWrapBox(slotW)
            end
        end
        invScroll:AddChild(invWrap)
        local sBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
        pcall(function()
            sBox:SetWidthOverride(360.0)
            sBox:SetHeightOverride(560.0)
        end)
        sBox:AddChild(invScroll)
        leftVBox:AddChildToVerticalBox(sBox)
    end

    local leftSlot = mainHBox:AddChildToHorizontalBox(leftVBox)
    if Core.IsValidObj(leftSlot) then
        pcall(function() leftSlot:SetPadding({ Left = 8.0, Top = 8.0, Right = 16.0, Bottom = 8.0 }) end)
    end

    -- Right Column: Production Machines & Rates (Icon-heavy)
    local rightVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local machHeader = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
    local machScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local machListBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)

    if Core.IsValidObj(machHeader) then
        pcall(function()
            machHeader:SetSize(14)
            machHeader:SetText(Core.MakeText(string.format("Production (%d)", #assemblers)))
        end)
        rightVBox:AddChildToVerticalBox(machHeader)
    end

    if Core.IsValidObj(machListBox) and Core.IsValidObj(machScroll) then
        for _, entry in ipairs(assemblers) do
            local rowBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
            local rowHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
            local statusBar = Core.CreateRawWidget(PATHS.BorderClass, outer)
            local statusSize = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)

            if Core.IsValidObj(rowBorder) and Core.IsValidObj(rowHBox) and Core.IsValidObj(statusBar) and Core.IsValidObj(statusSize) then
                -- Determine bottleneck status: consuming faster than station produces?
                local hasDeficit = false
                for _, inp in ipairs(entry.Inputs) do
                    local k = StationData.GetObjectKey(inp.Item) or tostring(inp.Item:GetAddress())
                    local pRate = prodRates[k] or 0.0
                    local cRate = consRates[k] or 0.0
                    if cRate > pRate + 0.001 then
                        hasDeficit = true
                        break
                    end
                end

                local statusCol = STATUS_COLORS.Green
                if not entry.HasRecipe then
                    statusCol = STATUS_COLORS.Amber
                elseif hasDeficit then
                    statusCol = STATUS_COLORS.Red
                end

                pcall(function()
                    rowBorder:SetBrushColor(STATUS_COLORS.RowBg)
                    rowBorder:SetPadding({ Left = 6.0, Top = 6.0, Right = 8.0, Bottom = 6.0 })
                    statusBar:SetBrushColor(statusCol)
                    statusSize:SetWidthOverride(6.0)
                    statusSize:SetHeightOverride(28.0)
                end)
                statusSize:AddChild(statusBar)

                local stSlot = rowHBox:AddChildToHorizontalBox(statusSize)
                if Core.IsValidObj(stSlot) then
                    pcall(function()
                        stSlot:SetVerticalAlignment(2)
                        stSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 8.0, Bottom = 0.0 })
                    end)
                end

                -- Compact machine name
                local nameTxt = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
                if Core.IsValidObj(nameTxt) then
                    pcall(function()
                        nameTxt:SetSize(12)
                        nameTxt:SetText(Core.MakeText(entry.Name))
                    end)
                    local nBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
                    pcall(function() nBox:SetWidthOverride(130.0) end)
                    nBox:AddChild(nameTxt)
                    local nSlot = rowHBox:AddChildToHorizontalBox(nBox)
                    if Core.IsValidObj(nSlot) then
                        pcall(function() nSlot:SetVerticalAlignment(2) end)
                    end
                end

                -- Ingredient icons + rates
                for _, inp in ipairs(entry.Inputs) do
                    local k = StationData.GetObjectKey(inp.Item) or tostring(inp.Item:GetAddress())
                    local pRate = prodRates[k] or 0.0
                    local cRate = consRates[k] or 0.0
                    local chipTint = (cRate > pRate + 0.001) and STATUS_COLORS.Red or nil
                    AddItemRateChip(rowHBox, win, pc, outer, inp.Item, inp.Rate, chipTint)
                end

                -- Arrow separator
                if #entry.Inputs > 0 and #entry.Outputs > 0 then
                    local arrowTxt = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
                    if Core.IsValidObj(arrowTxt) then
                        pcall(function()
                            arrowTxt:SetSize(13)
                            arrowTxt:SetText(Core.MakeText("→"))
                        end)
                        local aSlot = rowHBox:AddChildToHorizontalBox(arrowTxt)
                        if Core.IsValidObj(aSlot) then
                            pcall(function()
                                aSlot:SetVerticalAlignment(2)
                                aSlot:SetPadding({ Left = 2.0, Top = 0.0, Right = 10.0, Bottom = 0.0 })
                            end)
                        end
                    end
                end

                -- Output icons + rates
                for _, outp in ipairs(entry.Outputs) do
                    AddItemRateChip(rowHBox, win, pc, outer, outp.Item, outp.Rate, STATUS_COLORS.Green)
                end

                rowBorder:AddChild(rowHBox)
                local rSlot = machListBox:AddChildToVerticalBox(rowBorder)
                if Core.IsValidObj(rSlot) then
                    pcall(function() rSlot:SetPadding({ Left = 0.0, Top = 2.0, Right = 0.0, Bottom = 2.0 }) end)
                end
            end
        end

        machScroll:AddChild(machListBox)
        local mBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
        pcall(function()
            mBox:SetWidthOverride(640.0)
            mBox:SetHeightOverride(560.0)
        end)
        mBox:AddChild(machScroll)
        rightVBox:AddChildToVerticalBox(mBox)
    end

    local rightSlot = mainHBox:AddChildToHorizontalBox(rightVBox)
    if Core.IsValidObj(rightSlot) then
        pcall(function()
            rightSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            rightSlot:SetPadding({ Left = 8.0, Top = 8.0, Right = 8.0, Bottom = 8.0 })
        end)
    end

    rootBox:AddChildToVerticalBox(mainHBox)
end

local function ToggleLogistics()
    if Core.IsValidObj(ActiveLogisticsWin) then
        CloseLogisticsWindow()
        return
    end

    if IsSelectingAnyKeybind()
        or Core.IsAnyWidgetClassVisible("WBP_SettingsMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_PauseMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_MainMenu_C")
    then
        return
    end

    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) or not pc.CharacterInputEnabled then
        return
    end

    OpenLogisticsWindow()
end

--------------------------------------------------------------------------------
-- Keybind Registration & Fallback Polling
--------------------------------------------------------------------------------

local function StartFallbackKeyPollIfNeeded()
    if FallbackPollActive then return end
    local keyName = Core.Config.LogisticsKey
    if ActiveUe4ssKey ~= nil or keyName == "None" or keyName == "" then
        return
    end

    FallbackPollActive = true
    FallbackWasDown = false

    local function PollTick()
        local curKey = Core.Config.LogisticsKey
        if ActiveUe4ssKey ~= nil or curKey == "None" or curKey == "" then
            FallbackPollActive = false
            return
        end

        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) then
            local okDown, isDown = pcall(function()
                return pc:IsInputKeyDown({ KeyName = FName(curKey) })
            end)
            if okDown then
                if isDown and not FallbackWasDown then
                    FallbackWasDown = true
                    ToggleLogistics()
                elseif not isDown then
                    FallbackWasDown = false
                end
            else
                FallbackWasDown = false
            end
        end

        ExecuteInGameThreadWithDelay(33, PollTick)
    end

    ExecuteInGameThreadWithDelay(33, PollTick)
end

local function ApplyLogisticsKeybind(keyName, shouldSave)
    local normalized = (keyName and keyName ~= "") and keyName or "None"
    Core.Config.LogisticsKey = normalized
    if shouldSave then
        Core.WriteConfig()
    end

    UpdateAllHudKeyIndicators()

    local ue4ssKey = ResolveUE4SSKey(normalized)
    ActiveUe4ssKey = ue4ssKey
    FallbackWasDown = false

    if ue4ssKey ~= nil then
        if not RegisteredKeyHandlers[ue4ssKey] then
            RegisteredKeyHandlers[ue4ssKey] = true
            RegisterKeyBind(ue4ssKey, function()
                if ActiveUe4ssKey == ue4ssKey then
                    ExecuteInGameThread(ToggleLogistics)
                end
            end)
        end
    else
        StartFallbackKeyPollIfNeeded()
    end
end

--------------------------------------------------------------------------------
-- Settings Menu (Controls) Row & Bottom-Right HUD Keybind Indicator
--------------------------------------------------------------------------------

local function SyncRemapRowDisplay(row)
    if not Core.IsValidObj(row) then return end

    row.MappingName = FName(MAPPING_NAME)
    local label = Core.MakeText("Logistics")
    row.InputActionText = label

    if Core.IsValidObj(row.WBP_SettingEntryBody) then
        pcall(function() row.WBP_SettingEntryBody:SetText(label) end)
    end

    if Core.IsValidObj(row.InputKeySelector) then
        pcall(function() row.InputKeySelector:SetSelectedKey(MakeInputChord(Core.Config.LogisticsKey)) end)
    end
end

local function IsEqolRemapRow(row)
    if not Core.IsValidObj(row) then return false end
    local addr = row:GetAddress()
    if TrackedRemapRows[addr] then return true end
    local okName, mName = pcall(function() return row.MappingName:ToString() end)
    if okName and mName == MAPPING_NAME then
        TrackedRemapRows[addr] = row
        return true
    end
    return false
end

local function EnsureSettingsKeybindRow(menu)
    if not Core.IsValidObj(menu) then return end
    local scrollBox = menu.ControlSettings
    if not Core.IsValidObj(scrollBox) then return end

    local menuAddr = menu:GetAddress()
    local existing = InjectedSettingsRows[menuAddr]
    if Core.IsValidObj(existing) then
        local okHas, hasChild = pcall(function() return scrollBox:HasChild(existing) end)
        if okHas and hasChild then
            SyncRemapRowDisplay(existing)
            return
        end
    end

    local pc = Core.IsValidObj(menu.PC) and menu.PC or Core.GetLocalPlayerController()
    local row = Core.CreateUserWidget(PATHS.InputRemapClass, menu, pc)
    if not Core.IsValidObj(row) then return end

    InjectedSettingsRows[menuAddr] = row
    TrackedRemapRows[row:GetAddress()] = row
    row.MappingName = FName(MAPPING_NAME)

    local slot = scrollBox:AddChild(row)
    if Core.IsValidObj(slot) then
        local refRow = Core.IsValidObj(menu.StatusWindow) and menu.StatusWindow or menu.Statistics
        if Core.IsValidObj(refRow) and Core.IsValidObj(refRow.Slot) then
            pcall(function()
                slot:SetPadding(refRow.Slot.Padding)
                slot:SetHorizontalAlignment(refRow.Slot.HorizontalAlignment)
                slot:SetVerticalAlignment(refRow.Slot.VerticalAlignment)
            end)
        end
    end

    SyncRemapRowDisplay(row)
    Core.Log("Injected Logistics keybind row into WBP_SettingsMenu_C")
end

local function EnsureHudKeybindIndicator(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    if HudKeyIndicators[addr] and Core.IsValidObj(HudKeyIndicators[addr].Root) then
        return
    end

    local container = hud.HUDInputContainer
    if not Core.IsValidObj(container) then return end

    local outer = Core.GetWidgetOuter(hud)
    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local rowHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local keyBadge = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local keyTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)
    local labelTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)

    if not (Core.IsValidObj(rowHBox) and Core.IsValidObj(keyBadge) and Core.IsValidObj(keyTxt) and Core.IsValidObj(labelTxt)) then
        return
    end

    local keyStr = tostring(Core.Config.LogisticsKey or DEFAULT_KEY)
    if keyStr == "None" or keyStr == "" then keyStr = "-" end

    pcall(function()
        keyBadge:SetBrushColor(STATUS_COLORS.KeyBg)
        keyBadge:SetPadding({ Left = 7.0, Top = 3.0, Right = 7.0, Bottom = 3.0 })
        keyTxt:SetSize(12)
        keyTxt:SetText(Core.MakeText(keyStr))
        labelTxt:SetSize(12)
        labelTxt:SetText(Core.MakeText("Logistics"))
    end)

    keyBadge:AddChild(keyTxt)
    local s1 = rowHBox:AddChildToHorizontalBox(keyBadge)
    if Core.IsValidObj(s1) then
        pcall(function()
            s1:SetVerticalAlignment(2)
            s1:SetPadding({ Left = 0.0, Top = 0.0, Right = 8.0, Bottom = 0.0 })
        end)
    end
    local s2 = rowHBox:AddChildToHorizontalBox(labelTxt)
    if Core.IsValidObj(s2) then
        pcall(function() s2:SetVerticalAlignment(2) end)
    end

    local nextRow = 6
    pcall(function()
        local children = container:GetAllChildren()
        if children then
            local count = 0
            StationData.ForEachArray(children, function() count = count + 1 end)
            nextRow = count
        end
    end)

    local gSlot = container:AddChildToGrid(rowHBox, nextRow, 0)
    if Core.IsValidObj(gSlot) then
        pcall(function()
            gSlot:SetPadding({ Left = 0.0, Top = 4.0, Right = 0.0, Bottom = 0.0 })
            gSlot:SetHorizontalAlignment(3) -- Right
        end)
    end

    HudKeyIndicators[addr] = { Root = rowHBox, KeyText = keyTxt }
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_SettingsMenu_C = function(menu)
        EnsureSettingsKeybindRow(menu)
    end,
    WBP_CharacterHUD_C = function(hud)
        EnsureHudKeybindIndicator(hud)
    end,
}

function Feature.Init()
    Core.ReadConfig({ LogisticsKey = DEFAULT_KEY })
    ApplyLogisticsKeybind(Core.Config.LogisticsKey, false)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "SettingsMenu_Setup_Logistics",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Setup",
        function(Context)
            local menu = Context:get()
            if Core.IsValidObj(menu) then EnsureSettingsKeybindRow(menu) end
        end
    )

    Core.TryRegisterHook(
        "SettingsMenu_Refresh_Logistics",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Refresh",
        function(Context)
            local menu = Context:get()
            if Core.IsValidObj(menu) then EnsureSettingsKeybindRow(menu) end
        end
    )

    Core.TryRegisterHook(
        "InputRemap_OnKeySelected_Logistics",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_InputKeySelector_K2Node_ComponentBoundEvent_0_OnKeySelected__DelegateSignature",
        function(Context, SelectedKeyParam)
            local row = Context:get()
            if not IsEqolRemapRow(row) then return end

            local okKey, keyName = pcall(function()
                local chord = (type(SelectedKeyParam.get) == "function") and SelectedKeyParam:get() or SelectedKeyParam
                return chord.Key.KeyName:ToString()
            end)
            if okKey and keyName and keyName ~= "" and keyName ~= "None" then
                ApplyLogisticsKeybind(keyName, true)
            end
            SyncRemapRowDisplay(row)
        end
    )

    Core.TryRegisterHook(
        "InputRemap_Revert_Logistics",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_RevertToDefaultButton_K2Node_ComponentBoundEvent_1_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not IsEqolRemapRow(row) then return end
            ApplyLogisticsKeybind(DEFAULT_KEY, true)
            SyncRemapRowDisplay(row)
        end
    )

    Core.TryRegisterHook(
        "InputRemap_Clear_Logistics",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_ClearMappingButton_K2Node_ComponentBoundEvent_2_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not IsEqolRemapRow(row) then return end
            ApplyLogisticsKeybind("None", true)
            SyncRemapRowDisplay(row)
        end
    )

    Core.TryRegisterHook(
        "CharacterHUD_RefreshKeybinds_Logistics",
        "/Game/Blueprints/Widgets/HUDs/WBP_CharacterHUD.WBP_CharacterHUD_C:RefreshKeybinds",
        function(Context)
            local hud = Context:get()
            if Core.IsValidObj(hud) then
                EnsureHudKeybindIndicator(hud)
                UpdateAllHudKeyIndicators()
            end
        end
    )

    local okMenus, menus = pcall(FindAllOf, "WBP_SettingsMenu_C")
    if okMenus and menus then
        for _, m in ipairs(menus) do
            if Core.IsValidObj(m) then EnsureSettingsKeybindRow(m) end
        end
    end

    local okHuds, huds = pcall(FindAllOf, "WBP_CharacterHUD_C")
    if okHuds and huds then
        for _, h in ipairs(huds) do
            if Core.IsValidObj(h) then EnsureHudKeybindIndicator(h) end
        end
    end
end

function Feature.PruneCaches()
    for addr, row in pairs(InjectedSettingsRows) do
        if not Core.IsValidObj(row) then InjectedSettingsRows[addr] = nil end
    end
    for addr, row in pairs(TrackedRemapRows) do
        if not Core.IsValidObj(row) then TrackedRemapRows[addr] = nil end
    end
    for addr, entry in pairs(HudKeyIndicators) do
        if not Core.IsValidObj(entry.Root) then HudKeyIndicators[addr] = nil end
    end
    if ActiveLogisticsWin and not Core.IsValidObj(ActiveLogisticsWin) then
        ActiveLogisticsWin = nil
    end
end

return Feature
