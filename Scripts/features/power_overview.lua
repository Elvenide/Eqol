-- Eqol Feature: Power Overview
-- 1. Customizable hotkey (default P, configurable in Settings -> Controls) to toggle Power Overview
--    inside both space stations and spaceships.
-- 2. Summary header progress bars (Production, Consumption, and Power Satisfaction) in WBP_PowerOverview.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "PowerOverview",
}

local DEFAULT_KEY = "P"
local MAPPING_NAME = "Eqol_PowerOverview"

local PATHS = {
    PowerOverviewClass = "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C",
    SettingsMenuClass  = "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C",
    InputRemapClass    = "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C",
    ProgressBarClass   = "/Game/Blueprints/Widgets/Basic/WBP_ProgressBar.WBP_ProgressBar_C",
    TextClass          = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    IMCSystem          = "/Game/Data/Input/IMC_System.IMC_System",
    IAEscape           = "/Game/Data/Input/Common/IA_Escape.IA_Escape",
    DetailsStringTable = "/Game/Data/Localization/STB_Details.STB_Details",
}

-- Exact FLinearColor values extracted from WBP_PowerGrid
local STATUS_COLORS = {
    Green = { R = 0.05402, G = 0.7042, B = 0.05281, A = 1.0 },
    Amber = { R = 0.8917,  G = 0.6242, B = 0.0,     A = 1.0 },
    Red   = { R = 0.5177,  G = 0.0,    B = 0.04122, A = 1.0 },
}

-- Unreal FKey.KeyName -> UE4SS Key.* enum mapping
local UE_TO_UE4SS_KEY = {
    BackSpace         = Key and Key.BACKSPACE,
    Tab               = Key and Key.TAB,
    Enter             = Key and Key.RETURN,
    Return            = Key and Key.RETURN,
    Pause             = Key and Key.PAUSE,
    CapsLock          = Key and Key.CAPS_LOCK,
    Escape            = Key and Key.ESCAPE,
    SpaceBar          = Key and Key.SPACE,
    PageUp            = Key and Key.PAGE_UP,
    PageDown          = Key and Key.PAGE_DOWN,
    End               = Key and Key.END,
    Home              = Key and Key.HOME,
    Left              = Key and Key.LEFT_ARROW,
    Up                = Key and Key.UP_ARROW,
    Right             = Key and Key.RIGHT_ARROW,
    Down              = Key and Key.DOWN_ARROW,
    Insert            = Key and Key.INS,
    Delete            = Key and Key.DEL,
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
    NumPadZero        = Key and Key.NUM_ZERO,
    NumPadOne         = Key and Key.NUM_ONE,
    NumPadTwo         = Key and Key.NUM_TWO,
    NumPadThree       = Key and Key.NUM_THREE,
    NumPadFour        = Key and Key.NUM_FOUR,
    NumPadFive        = Key and Key.NUM_FIVE,
    NumPadSix         = Key and Key.NUM_SIX,
    NumPadSeven       = Key and Key.NUM_SEVEN,
    NumPadEight       = Key and Key.NUM_EIGHT,
    NumPadNine        = Key and Key.NUM_NINE,
    Multiply          = Key and Key.MULTIPLY,
    Add               = Key and Key.ADD,
    Subtract          = Key and Key.SUBTRACT,
    Decimal           = Key and Key.DECIMAL,
    Divide            = Key and Key.DIVIDE,
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
    LeftMouseButton   = Key and Key.LEFT_MOUSE_BUTTON,
    RightMouseButton  = Key and Key.RIGHT_MOUSE_BUTTON,
    MiddleMouseButton = Key and Key.MIDDLE_MOUSE_BUTTON,
    ThumbMouseButton  = Key and Key.XBUTTON_ONE,
    ThumbMouseButton2 = Key and Key.XBUTTON_TWO,
}

local ActiveUe4ssKey = nil
local RegisteredKeyHandlers = {}
local FallbackPollActive = false
local FallbackWasDown = false
local UnmappedPFromSystem = false
local AllHooksLogged = false

-- Per-widget state keyed by UObject memory address to prevent duplicate UI injection
local InjectedOverviews = {}
local InjectedSettingsRows = {}
local TrackedRemapRows = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function GetPowerOverviewDisplayText()
    local ktl = Core.GetCDO(Core.PATHS.KismetTextLibCDO)
    if Core.IsValidObj(ktl) then
        local ok, txt = pcall(function()
            return ktl:TextFromStringTable(FName(PATHS.DetailsStringTable), "PowerOverview")
        end)
        if ok and txt then
            local okStr, s = pcall(function() return txt:ToString() end)
            if okStr and s and s ~= "" and s ~= "<MISSING STRING TABLE ENTRY>" then
                return txt
            end
        end
    end
    return Core.MakeText("Power Overview")
end

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

--------------------------------------------------------------------------------
-- Power Overview Hotkey (Space Stations)
--------------------------------------------------------------------------------

local function ResolvePlayerFrameAndGrid(playerObj)
    if not Core.IsValidObj(playerObj) then return nil, nil end

    local candidates = {}
    local okFrame, walkFrame = pcall(function() return playerObj:GetFrame() end)
    if okFrame and Core.IsValidObj(walkFrame) then
        table.insert(candidates, walkFrame)
    end

    for _, frame in ipairs(candidates) do
        local pg = nil
        if frame.GetPowerGrid then
            local okPG, resPG = pcall(function() return frame:GetPowerGrid() end)
            if okPG and Core.IsValidObj(resPG) then
                pg = resPG
            end
        end
        if not Core.IsValidObj(pg) and Core.IsValidObj(frame.PowerGrid) then
            pg = frame.PowerGrid
        end
        if Core.IsValidObj(pg) then
            return frame, pg
        end
    end

    return nil, nil
end

local function TogglePowerOverview()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then
        Core.Log("TogglePowerOverview: no PlayerController")
        return
    end

    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if not Core.IsValidObj(widgetSub) then
        Core.Log("TogglePowerOverview: no WidgetSubsystem")
        return
    end

    if Core.IsAnyTextInputFocused() then
        return
    end

    local powerOverviewClass = Core.FindOrLoadClass(PATHS.PowerOverviewClass)
    if Core.IsValidObj(powerOverviewClass) then
        Core.EnsureAllHooks()
    end

    -- Close if WBP_PowerOverview is already the active window
    local curWin = widgetSub.CurrentWindow
    if Core.IsValidObj(curWin) then
        if Core.IsValidObj(powerOverviewClass) and curWin:IsA(powerOverviewClass) then
            pcall(function() widgetSub:CloseCurrentWindow() end)
        else
            Core.Log("TogglePowerOverview: another window is active")
        end
        return
    end

    -- Do not trigger while navigating menus, rebinding keys, or typing in inputs
    if IsSelectingAnyKeybind()
        or Core.IsAnyTextInputFocused()
        or Core.IsAnyWidgetClassVisible("WBP_SettingsMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_PauseMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_MainMenu_C")
    then
        Core.Log("TogglePowerOverview: blocked by visible menu/keybind selector")
        return
    end

    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then
        Core.Log("TogglePowerOverview: no PlayerObject")
        return
    end

    -- Prevent opening Power Management while on a ship (only supported on stations)
    local inStation = StationData.IsPlayerInStation(pc)
    if not inStation then
        Core.Log("TogglePowerOverview: blocked (player is not on a station)")
        return
    end

    if not pc.CharacterInputEnabled then
        Core.Log("TogglePowerOverview: blocked (CharacterInputEnabled=false)")
        return
    end

    local frame, powerGrid = ResolvePlayerFrameAndGrid(playerObj)
    if not Core.IsValidObj(frame) or not Core.IsValidObj(powerGrid) or not Core.IsValidObj(powerOverviewClass) then
        Core.Log("TogglePowerOverview: missing frame, powerGrid, or WBP_PowerOverview class")
        return
    end

    local gridOwner = frame
    local worldSub = Core.GetWorldSubsystem(pc, Core.PATHS.WorldSubsystemClass)
    if Core.IsValidObj(worldSub) then
        local okOwner, obj = pcall(function() return worldSub:GetObject(powerGrid.ParentID) end)
        if okOwner and Core.IsValidObj(obj) then
            gridOwner = obj
        end
    end

    local okShow, errShow = pcall(function()
        widgetSub:ShowWindow(powerOverviewClass, gridOwner, nil, false)
    end)
    if not okShow then
        Core.Log("TogglePowerOverview: ShowWindow failed: " .. tostring(errShow))
        pcall(function()
            pc:ToggleWidget(powerOverviewClass, gridOwner, nil)
        end)
    end
end

local function StartFallbackKeyPollIfNeeded()
    if FallbackPollActive then return end
    local keyName = Core.Config.PowerOverviewKey
    if ActiveUe4ssKey ~= nil or keyName == "None" or keyName == "" then
        return
    end

    FallbackPollActive = true
    FallbackWasDown = false

    local function PollTick()
        local curKey = Core.Config.PowerOverviewKey
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
                    TogglePowerOverview()
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

local function SyncIMCSystemBinding(forceRebuild)
    local imcSystem = Core.FindOrLoadClass(PATHS.IMCSystem)
    local iaEscape = Core.FindOrLoadClass(PATHS.IAEscape)
    if not Core.IsValidObj(imcSystem) or not Core.IsValidObj(iaEscape) then
        return
    end

    local keyP = { KeyName = FName("P") }
    local changed = false

    if Core.Config.PowerOverviewKey == "P" then
        if not UnmappedPFromSystem or forceRebuild then
            local wasUnmapped = UnmappedPFromSystem
            local okUnmap = pcall(function() imcSystem:UnmapKey(iaEscape, keyP) end)
            if okUnmap then
                UnmappedPFromSystem = true
                if not wasUnmapped or forceRebuild then
                    changed = true
                end
                if not wasUnmapped then
                    Core.Log("Unmapped P from IMC_System IA_Escape")
                end
            end
        end
    elseif UnmappedPFromSystem then
        local okMap = pcall(function() imcSystem:MapKey(iaEscape, keyP) end)
        if okMap then
            UnmappedPFromSystem = false
            changed = true
        end
    end

    if changed then
        local eiLib = Core.GetCDO(Core.PATHS.EnhancedInputLibCDO)
        if Core.IsValidObj(eiLib) then
            pcall(function() eiLib:RequestRebuildControlMappingsUsingContext(imcSystem, true) end)
        end
    end
end

local function ApplyPowerOverviewKeybind(keyName, shouldSave)
    local normalized = (keyName and keyName ~= "") and keyName or "None"
    Core.Config.PowerOverviewKey = normalized
    if shouldSave then
        Core.WriteConfig()
    end

    SyncIMCSystemBinding()

    local ue4ssKey = ResolveUE4SSKey(normalized)
    ActiveUe4ssKey = ue4ssKey
    FallbackWasDown = false

    if ue4ssKey ~= nil then
        if not RegisteredKeyHandlers[ue4ssKey] then
            RegisteredKeyHandlers[ue4ssKey] = true
            RegisterKeyBind(ue4ssKey, function()
                if ActiveUe4ssKey == ue4ssKey then
                    ExecuteInGameThread(TogglePowerOverview)
                end
            end)
        end
    else
        StartFallbackKeyPollIfNeeded()
    end
end

--------------------------------------------------------------------------------
-- Settings Menu (Controls) Native Keybind Row
--------------------------------------------------------------------------------

local function SyncRemapRowDisplay(row)
    if not Core.IsValidObj(row) then return end

    row.MappingName = FName(MAPPING_NAME)
    local label = GetPowerOverviewDisplayText()
    row.InputActionText = label

    if Core.IsValidObj(row.WBP_SettingEntryBody) then
        pcall(function() row.WBP_SettingEntryBody:SetText(label) end)
    end

    if Core.IsValidObj(row.InputKeySelector) then
        local chord = MakeInputChord(Core.Config.PowerOverviewKey)
        pcall(function() row.InputKeySelector:SetSelectedKey(chord) end)
    end
end

local function IsEqolRemapRow(row)
    if not Core.IsValidObj(row) then return false end
    local addr = row:GetAddress()
    if TrackedRemapRows[addr] then
        return true
    end
    local okName, mName = pcall(function() return row.MappingName:ToString() end)
    if okName and mName == MAPPING_NAME then
        TrackedRemapRows[addr] = row
        return true
    end
    return false
end

local function FindExistingRemapRowInScrollBox(scrollBox)
    if not Core.IsValidObj(scrollBox) then return nil end
    local okChildren, children = pcall(function() return scrollBox:GetAllChildren() end)
    if not okChildren or not children then return nil end

    local found = nil
    local okForEach = pcall(function()
        children:ForEach(function(_, elem)
            if found then return end
            local child = Core.UnwrapArrayElem(elem)
            if child and IsEqolRemapRow(child) then
                found = child
            end
        end)
    end)
    if okForEach then
        return found
    end

    for i = 1, #children do
        local child = Core.UnwrapArrayElem(children[i])
        if child and IsEqolRemapRow(child) then
            return child
        end
    end
    return nil
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

    local foundChild = FindExistingRemapRowInScrollBox(scrollBox)
    if Core.IsValidObj(foundChild) then
        InjectedSettingsRows[menuAddr] = foundChild
        TrackedRemapRows[foundChild:GetAddress()] = foundChild
        SyncRemapRowDisplay(foundChild)
        return
    end

    local pc = Core.IsValidObj(menu.PC) and menu.PC or Core.GetLocalPlayerController()
    local row = Core.CreateUserWidget(PATHS.InputRemapClass, menu, pc)
    if not Core.IsValidObj(row) then
        Core.Log("Failed to construct WBP_InputRemap_C for Controls settings")
        return
    end

    local rowAddr = row:GetAddress()
    InjectedSettingsRows[menuAddr] = row
    TrackedRemapRows[rowAddr] = row
    row.MappingName = FName(MAPPING_NAME)

    local slot = scrollBox:AddChild(row)
    if Core.IsValidObj(slot) then
        local refRow = Core.IsValidObj(menu.StatusWindow) and menu.StatusWindow or menu.Statistics
        if Core.IsValidObj(refRow) then
            if Core.IsValidObj(refRow.InputMappingContext) then
                pcall(function() row.InputMappingContext = refRow.InputMappingContext end)
            end
            if Core.IsValidObj(refRow.Slot) then
                pcall(function()
                    slot:SetPadding(refRow.Slot.Padding)
                    slot:SetHorizontalAlignment(refRow.Slot.HorizontalAlignment)
                    slot:SetVerticalAlignment(refRow.Slot.VerticalAlignment)
                end)
            end
        end
    end

    SyncRemapRowDisplay(row)
    Core.Log("Injected Power Overview keybind row into WBP_SettingsMenu_C")
end

local function InjectExistingSettingsMenus()
    local ok, menus = pcall(FindAllOf, "WBP_SettingsMenu_C")
    if not ok or not menus then return end
    for _, menu in ipairs(menus) do
        if Core.IsValidObj(menu) then
            EnsureSettingsKeybindRow(menu)
        end
    end
end

--------------------------------------------------------------------------------
-- Power Overview Header Progress Bars
--------------------------------------------------------------------------------

local function CopyTextStyle(dstText, srcText)
    if not Core.IsValidObj(dstText) or not Core.IsValidObj(srcText) then return end
    pcall(function()
        dstText.Size = srcText.Size
        dstText.Strength = srcText.Strength
        dstText.bOverrideColour = srcText.bOverrideColour
        dstText.Colour = srcText.Colour
        dstText.Justification = srcText.Justification
        if dstText.SetSize then dstText:SetSize(srcText.Size) end
        if dstText.SetColour then dstText:SetColour(srcText.Colour) end
        if dstText.SetJustification then dstText:SetJustification(srcText.Justification) end
        if dstText.PreConstruct then dstText:PreConstruct(false) end
        if Core.IsValidObj(srcText.TextBlock) and Core.IsValidObj(dstText.TextBlock) then
            dstText.TextBlock:SetColorAndOpacity(srcText.TextBlock.ColorAndOpacity)
        end
    end)
end

local function CreateSizedProgressBar(overviewWidget, owningPC, outer)
    local sizeBox = Core.CreateRawWidget(Core.PATHS.SizeBoxClass, outer)
    local bar = Core.CreateUserWidget(PATHS.ProgressBarClass, overviewWidget, owningPC)
    if not Core.IsValidObj(sizeBox) or not Core.IsValidObj(bar) then
        return nil, nil
    end

    pcall(function() sizeBox:SetHeightOverride(14.0) end)
    sizeBox:AddChild(bar)
    return sizeBox, bar
end

local function UpdateProgressBarWidget(barWidget, ratio, fillColor)
    if not Core.IsValidObj(barWidget) then return end
    local clamped = Core.Clamp(ratio, 0.0, 1.0)
    local pb = barWidget.ProgressBar
    if Core.IsValidObj(pb) then
        pcall(function()
            pb:SetPercent(clamped)
            pb:SetFillColorAndOpacity(fillColor)
        end)
    elseif barWidget.SetProgress then
        pcall(function() barWidget:SetProgress(clamped, 1.0) end)
    end
end

local function EnsureOverviewBars(overviewWidget)
    if not Core.IsValidObj(overviewWidget) then return nil end

    local addr = overviewWidget:GetAddress()
    local state = InjectedOverviews[addr]
    if state and Core.IsValidObj(state.Bar1) and Core.IsValidObj(state.Bar2) and Core.IsValidObj(state.Bar3) then
        return state
    end

    local totalProdText = overviewWidget.TotalProductionText
    local totalConsText = overviewWidget.TotalConsumptionText
    local solarValueText = overviewWidget.SolarEfficiencyText
    if not Core.IsValidObj(totalProdText) or not Core.IsValidObj(totalConsText) or not Core.IsValidObj(solarValueText) then
        return nil
    end

    local prodHBox = totalProdText:GetParent()
    local consHBox = totalConsText:GetParent()
    local solarHBox = solarValueText:GetParent()
    if not Core.IsValidObj(prodHBox) or not Core.IsValidObj(consHBox) or not Core.IsValidObj(solarHBox) then
        return nil
    end

    local prodVBox = prodHBox:GetParent()
    local consVBox = consHBox:GetParent()
    if not Core.IsValidObj(prodVBox) or not Core.IsValidObj(consVBox) then
        return nil
    end

    local gridPanel = prodVBox:GetParent()
    if not Core.IsValidObj(gridPanel) then
        return nil
    end

    local outer = Core.GetWidgetOuter(overviewWidget)
    local okPC, owningPC = pcall(function() return overviewWidget:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    -- Bar 1: Production Current / Max
    local bar1Box, bar1 = CreateSizedProgressBar(overviewWidget, pc, outer)
    if not Core.IsValidObj(bar1Box) then return nil end
    local bar1Slot = prodVBox:AddChildToVerticalBox(bar1Box)
    if Core.IsValidObj(bar1Slot) then
        pcall(function()
            bar1Slot:SetPadding({ Left = 32.0, Top = 8.0, Right = 32.0, Bottom = 4.0 })
            bar1Slot:SetHorizontalAlignment(0) -- HAlign_Fill
        end)
    end

    -- Bar 2: Consumption Current / Max
    local bar2Box, bar2 = CreateSizedProgressBar(overviewWidget, pc, outer)
    if not Core.IsValidObj(bar2Box) then return nil end
    local bar2Slot = consVBox:AddChildToVerticalBox(bar2Box)
    if Core.IsValidObj(bar2Slot) then
        pcall(function()
            bar2Slot:SetPadding({ Left = 32.0, Top = 8.0, Right = 32.0, Bottom = 4.0 })
            bar2Slot:SetHorizontalAlignment(0) -- HAlign_Fill
        end)
    end

    -- Bar 3: Power Satisfaction (Production / Consumption)
    local satVBox = Core.CreateRawWidget(Core.PATHS.VerticalBoxClass, outer)
    local satHeaderBox = Core.CreateRawWidget(Core.PATHS.HorizontalBoxClass, outer)
    local satLabelText = Core.CreateUserWidget(PATHS.TextClass, overviewWidget, pc)
    local satValueText = Core.CreateUserWidget(PATHS.TextClass, overviewWidget, pc)
    local bar3Box, bar3 = CreateSizedProgressBar(overviewWidget, pc, outer)
    if not (Core.IsValidObj(satVBox) and Core.IsValidObj(satHeaderBox) and Core.IsValidObj(satLabelText) and Core.IsValidObj(satValueText) and Core.IsValidObj(bar3Box)) then
        return nil
    end

    local okSolarLabel, solarLabelText = pcall(function() return solarHBox:GetChildAt(0) end)
    if okSolarLabel and Core.IsValidObj(solarLabelText) then
        CopyTextStyle(satLabelText, solarLabelText)
    end
    CopyTextStyle(satValueText, solarValueText)

    pcall(function()
        satLabelText:SetText(Core.MakeText("Power Satisfaction"))
        satValueText:SetText(Core.MakeText("0%"))
    end)

    local lblHSlot = satHeaderBox:AddChildToHorizontalBox(satLabelText)
    if Core.IsValidObj(lblHSlot) then
        pcall(function()
            lblHSlot:SetSize({ Value = 1.0, SizeRule = 1 }) -- Fill
            lblHSlot:SetVerticalAlignment(2) -- VAlign_Center
        end)
    end

    local valHSlot = satHeaderBox:AddChildToHorizontalBox(satValueText)
    if Core.IsValidObj(valHSlot) then
        pcall(function()
            valHSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            valHSlot:SetSize({ Value = 1.0, SizeRule = 0 }) -- Automatic
            valHSlot:SetVerticalAlignment(2) -- VAlign_Center
        end)
    end

    local hdrVSlot = satVBox:AddChildToVerticalBox(satHeaderBox)
    if Core.IsValidObj(hdrVSlot) then
        pcall(function() hdrVSlot:SetHorizontalAlignment(0) end)
    end

    local bar3Slot = satVBox:AddChildToVerticalBox(bar3Box)
    if Core.IsValidObj(bar3Slot) then
        pcall(function()
            bar3Slot:SetPadding({ Left = 0.0, Top = 6.0, Right = 0.0, Bottom = 0.0 })
            bar3Slot:SetHorizontalAlignment(0)
        end)
    end

    local targetRow = 1
    local targetCol = 2
    local cellPadding = { Left = 32.0, Top = 0.0, Right = 32.0, Bottom = 8.0 }

    local layoutLib = Core.GetCDO(Core.PATHS.WidgetLayoutLibCDO)
    local solarSlot = Core.IsValidObj(layoutLib) and select(2, pcall(function() return layoutLib:SlotAsGridSlot(solarHBox) end)) or nil
    if not Core.IsValidObj(solarSlot) then solarSlot = solarHBox.Slot end
    if Core.IsValidObj(solarSlot) then
        pcall(function()
            targetRow = solarSlot.Row
            cellPadding = solarSlot.Padding
            solarSlot:SetVerticalAlignment(1) -- VAlign_Top
        end)
    end

    local consSlot = Core.IsValidObj(layoutLib) and select(2, pcall(function() return layoutLib:SlotAsGridSlot(consVBox) end)) or nil
    if not Core.IsValidObj(consSlot) then consSlot = consVBox.Slot end
    if Core.IsValidObj(consSlot) then
        pcall(function() targetCol = consSlot.Column end)
    end

    local satGridSlot = gridPanel:AddChildToGrid(satVBox, targetRow, targetCol)
    if Core.IsValidObj(satGridSlot) then
        pcall(function()
            satGridSlot:SetPadding(cellPadding)
            satGridSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            satGridSlot:SetVerticalAlignment(1)   -- VAlign_Top
        end)
    end

    state = {
        Bar1 = bar1,
        Bar2 = bar2,
        Bar3 = bar3,
        SatValueText = satValueText,
    }
    InjectedOverviews[addr] = state
    return state
end

local function UpdateOverviewBars(overviewWidget)
    if not Core.IsValidObj(overviewWidget) then return end

    local state = EnsureOverviewBars(overviewWidget)
    if not state then return end

    local frame = overviewWidget.Frame
    if not Core.IsValidObj(frame) then return end

    local pg = frame.PowerGrid
    if not Core.IsValidObj(pg) and frame.GetPowerGrid then
        local okPG, resPG = pcall(function() return frame:GetPowerGrid() end)
        if okPG then pg = resPG end
    end
    if not Core.IsValidObj(pg) then return end

    local curProd = Core.GetFPFloat(pg.DisplayProduction)
    local maxProd = Core.GetFPFloat(pg.MaxProduction)
    local curCons = Core.GetFPFloat(pg.DisplayConsumption)
    local maxCons = Core.GetFPFloat(pg.MaxConsumption)

    -- Bar 1: Current / Max Production (Static Green)
    local prodRatio = (maxProd > 0.0001) and (curProd / maxProd) or 0.0
    UpdateProgressBarWidget(state.Bar1, prodRatio, STATUS_COLORS.Green)

    -- Bar 2: Current / Max Consumption (Static Green)
    local consRatio = (maxCons > 0.0001) and (curCons / maxCons) or 0.0
    UpdateProgressBarWidget(state.Bar2, consRatio, STATUS_COLORS.Green)

    -- Bar 3: Production out of Consumption (Dynamic Status Colors)
    local satRatio
    local satColor
    if curCons <= 0.0001 then
        if curProd > 0.0001 then
            satRatio = 1.0
            satColor = STATUS_COLORS.Green
        else
            satRatio = 0.0
            satColor = STATUS_COLORS.Red
        end
    else
        satRatio = curProd / curCons
        if satRatio >= 0.9999 then
            satColor = STATUS_COLORS.Green
        elseif satRatio >= 0.5 then
            satColor = STATUS_COLORS.Amber
        else
            satColor = STATUS_COLORS.Red
        end
    end

    UpdateProgressBarWidget(state.Bar3, satRatio, satColor)
    if Core.IsValidObj(state.SatValueText) then
        local pctInt = math.floor(satRatio * 100.0 + 0.5)
        pcall(function()
            state.SatValueText:SetText(Core.MakeText(string.format("%d%%", pctInt)))
        end)
    end
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_PowerOverview_C = function(widget)
        UpdateOverviewBars(widget)
    end,
    WBP_SettingsMenu_C = function(widget)
        EnsureSettingsKeybindRow(widget)
    end,
}

function Feature.Init()
    Core.ReadConfig({ PowerOverviewKey = DEFAULT_KEY })
    ApplyPowerOverviewKeybind(Core.Config.PowerOverviewKey, false)
end

local InitialSettingsScanDone = false

function Feature.RegisterHooks()
    local r1 = Core.TryRegisterHook(
        "PowerOverview_SetupWidget",
        "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C:SetupWidget",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) then
                UpdateOverviewBars(w)
            end
        end
    )

    local r2 = Core.TryRegisterHook(
        "PowerOverview_RefreshTotals",
        "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C:RefreshTotals",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) then
                UpdateOverviewBars(w)
            end
        end
    )

    local r3 = Core.TryRegisterHook(
        "PowerOverview_Refresh",
        "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C:Refresh",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) then
                UpdateOverviewBars(w)
            end
        end
    )

    local r4 = Core.TryRegisterHook(
        "SettingsMenu_Setup",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Setup",
        function(Context)
            local menu = Context:get()
            if Core.IsValidObj(menu) then
                EnsureSettingsKeybindRow(menu)
            end
        end
    )

    local r5 = Core.TryRegisterHook(
        "SettingsMenu_Refresh",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Refresh",
        function(Context)
            local menu = Context:get()
            if Core.IsValidObj(menu) then
                EnsureSettingsKeybindRow(menu)
            end
        end
    )

    local r6 = Core.TryRegisterHook(
        "SettingsMenu_RefreshInGame",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:RefreshInGame",
        function(Context)
            local menu = Context:get()
            if Core.IsValidObj(menu) then
                EnsureSettingsKeybindRow(menu)
            end
        end
    )

    local r7 = Core.TryRegisterHook(
        "InputRemap_LoadSettings",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:LoadSettings",
        function(Context)
            local row = Context:get()
            if IsEqolRemapRow(row) then
                SyncRemapRowDisplay(row)
            end
        end
    )

    local r8 = Core.TryRegisterHook(
        "InputRemap_RefreshDisplayKey",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:RefreshDisplayKey",
        function(Context)
            local row = Context:get()
            if IsEqolRemapRow(row) then
                SyncRemapRowDisplay(row)
            end
        end
    )

    local r9 = Core.TryRegisterHook(
        "InputRemap_OnKeySelected",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_InputKeySelector_K2Node_ComponentBoundEvent_0_OnKeySelected__DelegateSignature",
        function(Context, SelectedKeyParam)
            local row = Context:get()
            if not IsEqolRemapRow(row) then return end

            local okKey, keyName = pcall(function()
                local chord = (type(SelectedKeyParam.get) == "function") and SelectedKeyParam:get() or SelectedKeyParam
                return chord.Key.KeyName:ToString()
            end)
            if okKey and keyName and keyName ~= "" and keyName ~= "None" then
                ApplyPowerOverviewKeybind(keyName, true)
            end
            SyncRemapRowDisplay(row)
        end
    )

    local r10 = Core.TryRegisterHook(
        "InputRemap_Revert",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_RevertToDefaultButton_K2Node_ComponentBoundEvent_1_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not IsEqolRemapRow(row) then return end

            ApplyPowerOverviewKeybind(DEFAULT_KEY, true)
            SyncRemapRowDisplay(row)
        end
    )

    local r11 = Core.TryRegisterHook(
        "InputRemap_Clear",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_ClearMappingButton_K2Node_ComponentBoundEvent_2_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not IsEqolRemapRow(row) then return end

            ApplyPowerOverviewKeybind("None", true)
            SyncRemapRowDisplay(row)
        end
    )

    SyncIMCSystemBinding(false)
    if not InitialSettingsScanDone then
        InitialSettingsScanDone = true
        InjectExistingSettingsMenus()
    end

    if r1 and r2 and r3 and r4 and r5 and r6 and r7 and r8 and r9 and r10 and r11 and not AllHooksLogged then
        AllHooksLogged = true
        Core.Log("All PowerOverview Blueprint hooks registered")
    end
end

function Feature.OnClientRestart()
    SyncIMCSystemBinding(true)
    ExecuteInGameThreadWithDelay(500, function() SyncIMCSystemBinding(true) end)
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedOverviews) do
        if not Core.IsValidObj(st.Bar1) then
            InjectedOverviews[addr] = nil
        end
    end
    for addr, row in pairs(InjectedSettingsRows) do
        if not Core.IsValidObj(row) then
            InjectedSettingsRows[addr] = nil
        end
    end
    for addr, row in pairs(TrackedRemapRows) do
        if not Core.IsValidObj(row) then
            TrackedRemapRows[addr] = nil
        end
    end
end

return Feature
