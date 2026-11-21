-- Eqol Feature: Eqol Settings Tab
-- Adds an "Eqol Settings" tab to the native WBP_SettingsMenu_C screen with one checkbox
-- per toggleable Eqol feature, persisted automatically to config.json.

local Core = require("core")

local Feature = {
    Name       = "EqolSettings",
    Toggleable = false, -- Settings UI itself is always available
}

local PATHS = {
    WBPButtonClass     = "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C",
    WBPTextClass       = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WidgetSwitcherCls  = "/Script/UMG.WidgetSwitcher",
    PanelWidgetCls     = "/Script/UMG.PanelWidget",
    ScrollBoxClass     = "/Script/UMG.ScrollBox",
    VerticalBoxClass   = "/Script/UMG.VerticalBox",
    HorizontalBoxClass = "/Script/UMG.HorizontalBox",
    BorderClass        = "/Script/UMG.Border",
    OverlayClass       = "/Script/UMG.Overlay",
    SizeBoxClass       = "/Script/UMG.SizeBox",
}

local COLORS = {
    TabNormalBg     = { R = 0.08, G = 0.10, B = 0.13, A = 0.90 },
    TabActiveBg     = { R = 0.85, G = 0.56, B = 0.08, A = 0.96 },
    RowBg           = { R = 0.04, G = 0.05, B = 0.08, A = 0.65 },
    CheckOnBg       = { R = 0.85, G = 0.56, B = 0.08, A = 0.96 },
    CheckOffBg      = { R = 0.10, G = 0.12, B = 0.16, A = 0.95 },
    CheckMarkOn     = { R = 0.05, G = 0.06, B = 0.08, A = 1.00 },
    TitleText       = { R = 0.95, G = 0.96, B = 0.98, A = 1.00 },
    DescText        = { R = 0.66, G = 0.70, B = 0.76, A = 0.95 },
    HeaderText      = { R = 0.95, G = 0.70, B = 0.22, A = 1.00 },
}

local InjectedMenus = {} -- menuAddr -> { Menu, Switcher, EqolIndex, TabBtn, TabPage, Rows = { ... } }
local DiagLogged = false

local function SafeIsA(obj, cls)
    if not (Core.IsValidObj(obj) and Core.IsValidObj(cls)) then return false end
    local ok, res = pcall(function() return obj:IsA(cls) end)
    return ok and res == true
end

local function FindTabBarInTree(rootPanel, panelCls, btnCls, userWidgetCls, switcherAddr, depth, visited)
    if not Core.IsValidObj(rootPanel) or depth > 5 then return nil, nil end
    local addr = rootPanel:GetAddress()
    if addr == switcherAddr or visited[addr] then return nil, nil end
    visited[addr] = true

    if SafeIsA(rootPanel, panelCls) and rootPanel.GetAllChildren then
        local okCh, ch = pcall(function() return rootPanel:GetAllChildren() end)
        if okCh and ch then
            local okLen, len = pcall(function() return ch.GetArrayNum and ch:GetArrayNum() or #ch end)
            if okLen and type(len) == "number" and len > 0 then
                local btns = {}
                local uws = {}
                local childPanels = {}
                for i = 1, len do
                    local cw = Core.UnwrapArrayElem(ch[i])
                    if Core.IsValidObj(cw) and cw:GetAddress() ~= switcherAddr then
                        if SafeIsA(cw, btnCls) then
                            btns[#btns + 1] = cw
                        elseif SafeIsA(cw, userWidgetCls) then
                            uws[#uws + 1] = cw
                        elseif SafeIsA(cw, panelCls) then
                            childPanels[#childPanels + 1] = cw
                        end
                    end
                end
                if #btns >= 2 and #btns <= 8 then
                    return rootPanel, btns[#btns]
                end
                if #uws >= 2 and #uws <= 8 then
                    -- Check if these UserWidgets are tab buttons (e.g., WBP_TabButton_C / WBP_Button_C)
                    local cn = ""
                    pcall(function() cn = uws[1]:GetClass():GetFName():ToString():lower() end)
                    if cn:find("button", 1, true) or cn:find("tab", 1, true) then
                        return rootPanel, uws[#uws]
                    end
                end
                for _, cp in ipairs(childPanels) do
                    local tb, rb = FindTabBarInTree(cp, panelCls, btnCls, userWidgetCls, switcherAddr, depth + 1, visited)
                    if Core.IsValidObj(tb) then return tb, rb end
                end
            end
        end
    end
    return nil, nil
end

local function FindSettingsSwitcherAndTabBar(menu)
    if not Core.IsValidObj(menu) or not Core.IsValidObj(menu.ControlSettings) then
        return nil, nil, nil
    end

    local switcherCls = Core.FindOrLoadClass(PATHS.WidgetSwitcherCls)
    local panelCls = Core.FindOrLoadClass(PATHS.PanelWidgetCls)
    local btnCls = Core.FindOrLoadClass(PATHS.WBPButtonClass)
    local userWidgetCls = Core.FindOrLoadClass("/Script/UMG.UserWidget")

    local switcher = nil
    local topAncestor = menu.ControlSettings

    -- 1. Walk up from menu.ControlSettings to find the exact UWidgetSwitcher and its parent container
    local cur = menu.ControlSettings
    for _ = 1, 6 do
        if not cur.GetParent then break end
        local okP, p = pcall(function() return cur:GetParent() end)
        if not okP or not Core.IsValidObj(p) then break end
        topAncestor = p
        if not Core.IsValidObj(switcher) and SafeIsA(p, switcherCls) then
            switcher = p
        end
        cur = p
    end

    -- 2. Search from switcher's parent (and topAncestor) for the tab strip PanelWidget holding the tab buttons
    local tabBar, refTabBtn = nil, nil
    local switcherAddr = Core.IsValidObj(switcher) and switcher:GetAddress() or nil
    local visited = {}
    if Core.IsValidObj(switcher) and switcher.GetParent then
        local okSP, sp = pcall(function() return switcher:GetParent() end)
        if okSP and Core.IsValidObj(sp) then
            tabBar, refTabBtn = FindTabBarInTree(sp, panelCls, btnCls, userWidgetCls, switcherAddr, 0, visited)
        end
    end
    if not Core.IsValidObj(tabBar) and Core.IsValidObj(topAncestor) then
        tabBar, refTabBtn = FindTabBarInTree(topAncestor, panelCls, btnCls, userWidgetCls, switcherAddr, 0, visited)
    end

    if not DiagLogged then
        DiagLogged = true
        local swName = Core.IsValidObj(switcher) and switcher:GetFName():ToString() or "nil"
        local tbName = Core.IsValidObj(tabBar) and tabBar:GetFName():ToString() or "nil"
        local rbName = Core.IsValidObj(refTabBtn) and refTabBtn:GetFName():ToString() or "nil"
        Core.Log(string.format("[EqolSettings] Discovered switcher=%s tabBar=%s refBtn=%s", swName, tbName, rbName))
        if not Core.IsValidObj(tabBar) and Core.IsValidObj(switcher) and switcher.GetParent then
            local parts = {}
            pcall(function()
                local sp = switcher:GetParent()
                if Core.IsValidObj(sp) and sp.GetAllChildren then
                    local ch = sp:GetAllChildren()
                    local len = ch.GetArrayNum and ch:GetArrayNum() or #ch
                    for i = 1, len do
                        local cw = Core.UnwrapArrayElem(ch[i])
                        if Core.IsValidObj(cw) then
                            parts[#parts + 1] = cw:GetFName():ToString() .. ":" .. cw:GetClass():GetFName():ToString()
                        end
                    end
                end
            end)
            Core.Log("[EqolSettings] Switcher parent children: " .. table.concat(parts, ", "))
        end
    end

    return switcher, tabBar, refTabBtn
end

local function ApplyCheckboxVisual(rowState)
    if not rowState then return end
    local enabled = Core.IsFeatureEnabled(rowState.Name)
    if Core.IsValidObj(rowState.CheckBtn) then
        pcall(function()
            if rowState.CheckBtn.SetBackgroundColour then
                rowState.CheckBtn:SetBackgroundColour(enabled and COLORS.CheckOnBg or COLORS.CheckOffBg)
            end
        end)
    end
    if Core.IsValidObj(rowState.CheckMark) then
        pcall(function()
            rowState.CheckMark:SetText(Core.MakeText(enabled and "✓" or ""))
            if Core.IsValidObj(rowState.CheckMark.TextBlock) and rowState.CheckMark.TextBlock.SetColorAndOpacity then
                rowState.CheckMark.TextBlock:SetColorAndOpacity({
                    SpecifiedColor = COLORS.CheckMarkOn,
                    ColorUseRule = 0,
                })
            end
        end)
    end
    if Core.IsValidObj(rowState.TitleTxt) and Core.IsValidObj(rowState.TitleTxt.TextBlock) then
        pcall(function()
            rowState.TitleTxt.TextBlock:SetColorAndOpacity({
                SpecifiedColor = enabled and COLORS.TitleText or COLORS.DescText,
                ColorUseRule = 0,
            })
        end)
    end
end

local function SyncAllCheckboxes(menuState)
    if not menuState or not menuState.Rows then return end
    for _, r in ipairs(menuState.Rows) do
        ApplyCheckboxVisual(r)
    end
end

local function BuildFeatureRow(menu, pc, outer, featEntry)
    local rowBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local rowHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local chkSize = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local chkOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    local chkBtn = Core.CreateUserWidget(PATHS.WBPButtonClass, menu, pc)
    local chkMark = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    local textCol = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local titleTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    local descTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)

    if not (Core.IsValidObj(rowBorder) and Core.IsValidObj(rowHBox) and Core.IsValidObj(chkSize)
        and Core.IsValidObj(chkOverlay) and Core.IsValidObj(chkBtn) and Core.IsValidObj(chkMark)
        and Core.IsValidObj(textCol) and Core.IsValidObj(titleTxt) and Core.IsValidObj(descTxt)) then
        return nil, nil
    end

    local rowState = {
        Name      = featEntry.Name,
        CheckBtn  = chkBtn,
        CheckMark = chkMark,
        TitleTxt  = titleTxt,
        DescTxt   = descTxt,
    }

    pcall(function()
        rowBorder:SetBrushColor(COLORS.RowBg)
        rowBorder:SetPadding({ Left = 12.0, Top = 8.0, Right = 12.0, Bottom = 8.0 })

        chkSize:SetWidthOverride(26.0)
        chkSize:SetHeightOverride(26.0)
        chkBtn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })

        local bSlot = chkOverlay:AddChildToOverlay(chkBtn)
        if Core.IsValidObj(bSlot) then
            bSlot:SetHorizontalAlignment(0) -- Fill
            bSlot:SetVerticalAlignment(0)   -- Fill
        end
        local mSlot = chkOverlay:AddChildToOverlay(chkMark)
        if Core.IsValidObj(mSlot) then
            mSlot:SetHorizontalAlignment(2) -- Center
            mSlot:SetVerticalAlignment(2)   -- Center
        end
        chkSize:AddChild(chkOverlay)

        local cSlot = rowHBox:AddChildToHorizontalBox(chkSize)
        if Core.IsValidObj(cSlot) then
            cSlot:SetVerticalAlignment(2) -- Center
            cSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 14.0, Bottom = 0.0 })
        end

        textCol:AddChildToVerticalBox(titleTxt)
        if featEntry.Description and featEntry.Description ~= "" then
            textCol:AddChildToVerticalBox(descTxt)
        end

        local tSlot = rowHBox:AddChildToHorizontalBox(textCol)
        if Core.IsValidObj(tSlot) then
            tSlot:SetVerticalAlignment(2) -- Center
            tSlot:SetSize({ Value = 1.0, SizeRule = 1 })
        end

        rowBorder:AddChild(rowHBox)
    end)

    local function ApplyTextDefaults()
        pcall(function()
            chkMark:SetVisibility(3) -- HitTestInvisible so clicks reach chkBtn
            chkMark:SetSize(14)
            if Core.IsValidObj(chkMark.TextBlock) then chkMark.TextBlock:SetVisibility(3) end

            titleTxt:SetSize(13)
            titleTxt:SetText(Core.MakeText(featEntry.DisplayName or featEntry.Name))

            descTxt:SetSize(10)
            descTxt:SetText(Core.MakeText(featEntry.Description or ""))
            if Core.IsValidObj(descTxt.TextBlock) and descTxt.TextBlock.SetColorAndOpacity then
                descTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.DescText, ColorUseRule = 0 })
            end
        end)
        ApplyCheckboxVisual(rowState)
    end

    ApplyTextDefaults()
    ExecuteInGameThreadAfterFrames(1, function()
        if Core.IsValidObj(chkBtn) then ApplyTextDefaults() end
    end)

    -- Never do heavy work synchronously inside WBP_Button_C click hook (see learning.md §6)
    Core.RegisterWBPButtonClick(chkBtn, function()
        ExecuteInGameThreadWithDelay(10, function()
            local nextVal = not Core.IsFeatureEnabled(featEntry.Name)
            Core.SetFeatureEnabled(featEntry.Name, nextVal)
            ApplyCheckboxVisual(rowState)
        end)
    end)

    return rowBorder, rowState
end

local function EnsureEqolSettingsTab(menu)
    if not Core.IsValidObj(menu) then return end
    local menuAddr = menu:GetAddress()
    local existing = InjectedMenus[menuAddr]
    if existing and Core.IsValidObj(existing.TabBtn) and Core.IsValidObj(existing.TabPage) then
        SyncAllCheckboxes(existing)
        return
    end

    local switcher, tabBar, refTabBtn = FindSettingsSwitcherAndTabBar(menu)
    if not (Core.IsValidObj(switcher) and Core.IsValidObj(tabBar)) then
        return
    end

    local pc = Core.IsValidObj(menu.PC) and menu.PC or Core.GetLocalPlayerController()
    local outer = Core.GetWidgetOuter(menu)

    -- Build the Eqol Settings ScrollBox page
    local pageScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local pageVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local headerTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    local subTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    if not (Core.IsValidObj(pageScroll) and Core.IsValidObj(pageVBox)) then
        return
    end

    if Core.IsValidObj(headerTxt) then
        local hSlot = pageVBox:AddChildToVerticalBox(headerTxt)
        if Core.IsValidObj(hSlot) then
            pcall(function() hSlot:SetPadding({ Left = 4.0, Top = 4.0, Right = 4.0, Bottom = 2.0 }) end)
        end
    end
    if Core.IsValidObj(subTxt) then
        local sSlot = pageVBox:AddChildToVerticalBox(subTxt)
        if Core.IsValidObj(sSlot) then
            pcall(function() sSlot:SetPadding({ Left = 4.0, Top = 0.0, Right = 4.0, Bottom = 12.0 }) end)
        end
    end

    local function ApplyHeaderText()
        pcall(function()
            if Core.IsValidObj(headerTxt) then
                headerTxt:SetSize(16)
                headerTxt:SetText(Core.MakeText(string.format("Eqol Settings (v%s)", tostring(Core.VERSION or "0.1.0"))))
                if Core.IsValidObj(headerTxt.TextBlock) and headerTxt.TextBlock.SetColorAndOpacity then
                    headerTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.HeaderText, ColorUseRule = 0 })
                end
            end
            if Core.IsValidObj(subTxt) then
                subTxt:SetSize(10)
                subTxt:SetText(Core.MakeText("Enable or disable individual Eqol features. Changes apply immediately and are saved automatically."))
                if Core.IsValidObj(subTxt.TextBlock) and subTxt.TextBlock.SetColorAndOpacity then
                    subTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.DescText, ColorUseRule = 0 })
                end
            end
        end)
    end
    ApplyHeaderText()
    ExecuteInGameThreadAfterFrames(1, ApplyHeaderText)

    local rows = {}
    local features = Core.GetToggleableFeatures()
    for _, featEntry in ipairs(features) do
        local rowWidget, rowState = BuildFeatureRow(menu, pc, outer, featEntry)
        if Core.IsValidObj(rowWidget) and rowState then
            local rSlot = pageVBox:AddChildToVerticalBox(rowWidget)
            if Core.IsValidObj(rSlot) then
                pcall(function() rSlot:SetPadding({ Left = 0.0, Top = 3.0, Right = 8.0, Bottom = 3.0 }) end)
            end
            rows[#rows + 1] = rowState
        end
    end

    pcall(function() pageScroll:AddChild(pageVBox) end)
    pcall(function() switcher:AddChild(pageScroll) end)

    local eqolIdx = 0
    pcall(function()
        if switcher.GetChildIndex then
            eqolIdx = tonumber(switcher:GetChildIndex(pageScroll)) or 0
        elseif switcher.GetChildrenCount then
            eqolIdx = math.max(0, (tonumber(switcher:GetChildrenCount()) or 1) - 1)
        end
    end)

    -- Build the "Eqol Settings" tab button matching existing tab buttons
    local tabBtn = Core.CreateUserWidget(PATHS.WBPButtonClass, menu, pc)
    local tabTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    local tabOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    if not (Core.IsValidObj(tabBtn) and Core.IsValidObj(tabTxt) and Core.IsValidObj(tabOverlay)) then
        return
    end

    pcall(function()
        if tabBtn.SetBackgroundColour then
            tabBtn:SetBackgroundColour(COLORS.TabNormalBg)
        end
        tabBtn:SetContentPadding({ Left = 10.0, Top = 4.0, Right = 10.0, Bottom = 4.0 })
        local bSlot = tabOverlay:AddChildToOverlay(tabBtn)
        if Core.IsValidObj(bSlot) then
            bSlot:SetHorizontalAlignment(0)
            bSlot:SetVerticalAlignment(0)
        end
        local tSlot = tabOverlay:AddChildToOverlay(tabTxt)
        if Core.IsValidObj(tSlot) then
            tSlot:SetHorizontalAlignment(2)
            tSlot:SetVerticalAlignment(2)
            tSlot:SetPadding({ Left = 10.0, Top = 4.0, Right = 10.0, Bottom = 4.0 })
        end
    end)

    local function ApplyTabLabel()
        pcall(function()
            tabTxt:SetVisibility(3)
            tabTxt:SetSize(13)
            tabTxt:SetText(Core.MakeText("Eqol Settings"))
            if Core.IsValidObj(tabTxt.TextBlock) then
                tabTxt.TextBlock:SetVisibility(3)
                tabTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.TitleText, ColorUseRule = 0 })
            end
        end)
    end
    ApplyTabLabel()
    ExecuteInGameThreadAfterFrames(1, ApplyTabLabel)

    local addedSlot = nil
    pcall(function()
        if tabBar.AddChildToGrid then
            local refRow, refCol = 0, 0
            if Core.IsValidObj(refTabBtn) and Core.IsValidObj(refTabBtn.Slot) then
                pcall(function()
                    refRow = tonumber(refTabBtn.Slot.Row) or 0
                    refCol = tonumber(refTabBtn.Slot.Column) or 0
                end)
            end
            local targetRow, targetCol = refRow, refCol + 1
            if refRow > refCol then
                targetRow, targetCol = refRow + 1, refCol
            end
            addedSlot = tabBar:AddChildToGrid(tabOverlay, targetRow, targetCol)
        elseif tabBar.AddChildToHorizontalBox then
            addedSlot = tabBar:AddChildToHorizontalBox(tabOverlay)
        elseif tabBar.AddChildToVerticalBox then
            addedSlot = tabBar:AddChildToVerticalBox(tabOverlay)
        else
            addedSlot = tabBar:AddChild(tabOverlay)
        end
    end)

    if Core.IsValidObj(addedSlot) and Core.IsValidObj(refTabBtn) and Core.IsValidObj(refTabBtn.Slot) then
        pcall(function()
            addedSlot:SetPadding(refTabBtn.Slot.Padding)
            addedSlot:SetHorizontalAlignment(refTabBtn.Slot.HorizontalAlignment)
            addedSlot:SetVerticalAlignment(refTabBtn.Slot.VerticalAlignment)
        end)
    end

    local menuState = {
        Menu      = menu,
        Switcher  = switcher,
        EqolIndex = eqolIdx,
        TabBtn    = tabBtn,
        TabPage   = pageScroll,
        Rows      = rows,
    }
    InjectedMenus[menuAddr] = menuState

    Core.RegisterWBPButtonClick(tabBtn, function()
        ExecuteInGameThreadWithDelay(10, function()
            if Core.IsValidObj(switcher) and Core.IsValidObj(pageScroll) then
                pcall(function()
                    if switcher.SetActiveWidget then
                        switcher:SetActiveWidget(pageScroll)
                    else
                        switcher:SetActiveWidgetIndex(eqolIdx)
                    end
                end)
                SyncAllCheckboxes(menuState)
            end
        end)
    end)

    Core.Log(string.format("[EqolSettings] Injected Eqol Settings tab (idx=%d, features=%d)", eqolIdx, #rows))
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

function Feature.Init()
    Core.OnSettingsMenuReady(EnsureEqolSettingsTab)
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedMenus) do
        if not st or not Core.IsValidObj(st.Menu) then
            InjectedMenus[addr] = nil
        end
    end
end

return Feature
