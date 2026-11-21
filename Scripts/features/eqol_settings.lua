-- Eqol Feature: Eqol Settings Tab
-- Adds an "Eqol Settings" tab to the native WBP_SettingsMenu_C screen with one clickable
-- toggle card per Eqol feature, persisted automatically to config.json.
-- Cards are built lazily on first tab click so opening Pause / Settings (Esc) has zero hitch.

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
    Transparent     = { R = 0.00, G = 0.00, B = 0.00, A = 0.00 },
    TabLineActive   = { R = 0.95, G = 0.65, B = 0.12, A = 1.00 },
    TabLineInactive = { R = 0.72, G = 0.76, B = 0.80, A = 0.55 },
    TabTextActive   = { R = 0.95, G = 0.65, B = 0.12, A = 1.00 },
    TabTextInactive = { R = 0.94, G = 0.95, B = 0.97, A = 0.95 },
    RowBg           = { R = 0.04, G = 0.05, B = 0.08, A = 0.65 },
    CheckOnBg       = { R = 0.85, G = 0.56, B = 0.08, A = 0.96 },
    CheckOffBg      = { R = 0.10, G = 0.12, B = 0.16, A = 0.95 },
    CheckMarkOn     = { R = 0.05, G = 0.06, B = 0.08, A = 1.00 },
    TitleText       = { R = 0.95, G = 0.96, B = 0.98, A = 1.00 },
    DescText        = { R = 0.66, G = 0.70, B = 0.76, A = 0.95 },
    HeaderText      = { R = 0.95, G = 0.70, B = 0.22, A = 1.00 },
}

local InjectedMenus = {} -- menuAddr -> menuState
local DiagLogged = false

local function SafeIsA(obj, cls)
    if not (Core.IsValidObj(obj) and Core.IsValidObj(cls)) then return false end
    local ok, res = pcall(function() return obj:IsA(cls) end)
    return ok and res == true
end

local function FindTabBarInTree(rootPanel, panelCls, btnCls, userWidgetCls, switcherAddr, depth, visited)
    if not Core.IsValidObj(rootPanel) or depth > 5 then return nil, nil, nil end
    local addr = rootPanel:GetAddress()
    if addr == switcherAddr or visited[addr] then return nil, nil, nil end
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
                    return rootPanel, btns[#btns], btns
                end
                if #uws >= 2 and #uws <= 8 then
                    local cn = ""
                    pcall(function() cn = uws[1]:GetClass():GetFName():ToString():lower() end)
                    if cn:find("button", 1, true) or cn:find("tab", 1, true) then
                        return rootPanel, uws[#uws], uws
                    end
                end
                for _, cp in ipairs(childPanels) do
                    local tb, rb, sibs = FindTabBarInTree(cp, panelCls, btnCls, userWidgetCls, switcherAddr, depth + 1, visited)
                    if Core.IsValidObj(tb) then return tb, rb, sibs end
                end
            end
        end
    end
    return nil, nil, nil
end

local function FindSettingsSwitcherAndTabBar(menu)
    if not Core.IsValidObj(menu) or not Core.IsValidObj(menu.ControlSettings) then
        return nil, nil, nil, nil
    end

    local switcherCls = Core.FindOrLoadClass(PATHS.WidgetSwitcherCls)
    local panelCls = Core.FindOrLoadClass(PATHS.PanelWidgetCls)
    local btnCls = Core.FindOrLoadClass(PATHS.WBPButtonClass)
    local userWidgetCls = Core.FindOrLoadClass("/Script/UMG.UserWidget")

    local switcher = nil
    local topAncestor = menu.ControlSettings

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

    local tabBar, refTabBtn, siblingTabs = nil, nil, nil
    local switcherAddr = Core.IsValidObj(switcher) and switcher:GetAddress() or nil
    local visited = {}
    if Core.IsValidObj(switcher) and switcher.GetParent then
        local okSP, sp = pcall(function() return switcher:GetParent() end)
        if okSP and Core.IsValidObj(sp) then
            tabBar, refTabBtn, siblingTabs = FindTabBarInTree(sp, panelCls, btnCls, userWidgetCls, switcherAddr, 0, visited)
        end
    end
    if not Core.IsValidObj(tabBar) and Core.IsValidObj(topAncestor) then
        tabBar, refTabBtn, siblingTabs = FindTabBarInTree(topAncestor, panelCls, btnCls, userWidgetCls, switcherAddr, 0, visited)
    end

    if not DiagLogged then
        DiagLogged = true
        local swName = Core.IsValidObj(switcher) and switcher:GetFName():ToString() or "nil"
        local tbName = Core.IsValidObj(tabBar) and tabBar:GetFName():ToString() or "nil"
        local rbName = Core.IsValidObj(refTabBtn) and refTabBtn:GetFName():ToString() or "nil"
        Core.Log(string.format("[EqolSettings] Discovered switcher=%s tabBar=%s refBtn=%s", swName, tbName, rbName))
    end

    return switcher, tabBar, refTabBtn, siblingTabs or {}
end

local CleanTabMetaLogged = false

local function ApplyCleanTabState(tabWidget, isSelected)
    if not Core.IsValidObj(tabWidget) then return end
    pcall(function()
        if tabWidget.SetSelected then
            tabWidget:SetSelected(isSelected)
        elseif tabWidget.SetActive then
            tabWidget:SetActive(isSelected)
        elseif tabWidget.SetIsSelected then
            tabWidget:SetIsSelected(isSelected)
        elseif tabWidget.SelectTab then
            tabWidget:SelectTab(isSelected)
        end
    end)
end

local function SetCleanTabLabel(tabWidget, labelStr)
    if not Core.IsValidObj(tabWidget) then return end
    local txt = Core.MakeText(labelStr)
    pcall(function()
        if tabWidget.SetTitle then
            tabWidget:SetTitle(txt)
        elseif tabWidget.SetText then
            tabWidget:SetText(txt)
        elseif tabWidget.SetTabName then
            tabWidget:SetTabName(txt)
        end
        for _, prop in ipairs({ "WBP_Text", "Text", "Title", "Label", "TabText", "NameText" }) do
            local ok, v = pcall(function() return tabWidget[prop] end)
            if ok and Core.IsValidObj(v) and v.SetText then
                v:SetText(txt)
                break
            end
        end
    end)
end

local function FindCleanTabClickButton(tabWidget)
    if not Core.IsValidObj(tabWidget) then return nil end
    local btnCls = Core.FindOrLoadClass(PATHS.WBPButtonClass)
    if SafeIsA(tabWidget, btnCls) then return tabWidget end
    for _, prop in ipairs({ "WBP_Button", "Button", "TabButton", "Button_0", "CleanButton" }) do
        local ok, b = pcall(function() return tabWidget[prop] end)
        if ok and Core.IsValidObj(b) then
            return b
        end
    end
    return nil
end

local function SetEqolTabVisualActive(menuState, isActive)
    if not menuState then return end
    if menuState.IsNativeCleanTab and Core.IsValidObj(menuState.TabWidget) then
        ApplyCleanTabState(menuState.TabWidget, isActive)
    else
        if Core.IsValidObj(menuState.TabLine) then
            pcall(function()
                menuState.TabLine:SetBrushColor(isActive and COLORS.TabLineActive or COLORS.TabLineInactive)
            end)
        end
        if Core.IsValidObj(menuState.TabTxt) and Core.IsValidObj(menuState.TabTxt.TextBlock) then
            pcall(function()
                menuState.TabTxt.TextBlock:SetColorAndOpacity({
                    SpecifiedColor = isActive and COLORS.TabTextActive or COLORS.TabTextInactive,
                    ColorUseRule = 0,
                })
            end)
        end
    end
    if isActive and menuState.SiblingTabs then
        for _, sib in ipairs(menuState.SiblingTabs) do
            ApplyCleanTabState(sib, false)
        end
    end
end

local function ApplyCheckboxVisual(rowState)
    if not rowState then return end
    local enabled = Core.IsFeatureEnabled(rowState.Name)
    if Core.IsValidObj(rowState.CheckBoxBg) then
        pcall(function()
            rowState.CheckBoxBg:SetBrushColor(enabled and COLORS.CheckOnBg or COLORS.CheckOffBg)
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
    -- Full-card clickable Overlay: full-bleed WBP_Button_C behind HitTestInvisible card content
    local cardOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    local cardBtn = Core.CreateUserWidget(PATHS.WBPButtonClass, menu, pc)
    local rowBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local rowHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local chkSize = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local chkBg = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local chkMark = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    local textCol = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local titleTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    local descTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)

    if not (Core.IsValidObj(cardOverlay) and Core.IsValidObj(cardBtn) and Core.IsValidObj(rowBorder)
        and Core.IsValidObj(rowHBox) and Core.IsValidObj(chkSize) and Core.IsValidObj(chkBg)
        and Core.IsValidObj(chkMark) and Core.IsValidObj(textCol)
        and Core.IsValidObj(titleTxt) and Core.IsValidObj(descTxt)) then
        return nil, nil
    end

    local rowState = {
        Name       = featEntry.Name,
        CardBtn    = cardBtn,
        CheckBoxBg = chkBg,
        CheckMark  = chkMark,
        TitleTxt   = titleTxt,
        DescTxt    = descTxt,
    }

    pcall(function()
        if cardBtn.SetBackgroundColour then
            cardBtn:SetBackgroundColour(COLORS.RowBg)
        end
        cardBtn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })

        rowBorder:SetBrushColor(COLORS.Transparent)
        rowBorder:SetPadding({ Left = 12.0, Top = 8.0, Right = 12.0, Bottom = 8.0 })
        rowBorder:SetVisibility(3) -- HitTestInvisible so clicks anywhere on card hit cardBtn
        rowHBox:SetVisibility(3)

        chkSize:SetWidthOverride(26.0)
        chkSize:SetHeightOverride(26.0)
        chkSize:SetVisibility(3)
        chkBg:SetHorizontalAlignment(2) -- Center
        chkBg:SetVerticalAlignment(2)   -- Center
        chkBg:SetVisibility(3)
        chkBg:AddChild(chkMark)
        chkSize:AddChild(chkBg)

        local cSlot = rowHBox:AddChildToHorizontalBox(chkSize)
        if Core.IsValidObj(cSlot) then
            cSlot:SetVerticalAlignment(2)
            cSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 14.0, Bottom = 0.0 })
        end

        textCol:SetVisibility(3)
        textCol:AddChildToVerticalBox(titleTxt)
        if featEntry.Description and featEntry.Description ~= "" then
            textCol:AddChildToVerticalBox(descTxt)
        end

        local tSlot = rowHBox:AddChildToHorizontalBox(textCol)
        if Core.IsValidObj(tSlot) then
            tSlot:SetVerticalAlignment(2)
            tSlot:SetSize({ Value = 1.0, SizeRule = 1 })
        end

        rowBorder:AddChild(rowHBox)

        local bSlot = cardOverlay:AddChildToOverlay(cardBtn)
        if Core.IsValidObj(bSlot) then
            bSlot:SetHorizontalAlignment(0) -- Fill
            bSlot:SetVerticalAlignment(0)   -- Fill
        end
        local rSlot = cardOverlay:AddChildToOverlay(rowBorder)
        if Core.IsValidObj(rSlot) then
            rSlot:SetHorizontalAlignment(0) -- Fill
            rSlot:SetVerticalAlignment(0)   -- Fill
        end
    end)

    local function ApplyTextDefaults()
        pcall(function()
            chkMark:SetVisibility(3)
            chkMark:SetSize(14)
            if Core.IsValidObj(chkMark.TextBlock) then chkMark.TextBlock:SetVisibility(3) end

            titleTxt:SetVisibility(3)
            titleTxt:SetSize(13)
            titleTxt:SetText(Core.MakeText(featEntry.DisplayName or featEntry.Name))
            if Core.IsValidObj(titleTxt.TextBlock) then titleTxt.TextBlock:SetVisibility(3) end

            descTxt:SetVisibility(3)
            descTxt:SetSize(10)
            descTxt:SetText(Core.MakeText(featEntry.Description or ""))
            if Core.IsValidObj(descTxt.TextBlock) and descTxt.TextBlock.SetColorAndOpacity then
                descTxt.TextBlock:SetVisibility(3)
                descTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.DescText, ColorUseRule = 0 })
            end
        end)
        ApplyCheckboxVisual(rowState)
    end

    ApplyTextDefaults()
    ExecuteInGameThreadAfterFrames(1, function()
        if Core.IsValidObj(cardBtn) then ApplyTextDefaults() end
    end)

    -- Never do heavy work synchronously inside WBP_Button_C click hook (learning.md §6)
    Core.RegisterWBPButtonClick(cardBtn, function()
        ExecuteInGameThreadWithDelay(10, function()
            local nextVal = not Core.IsFeatureEnabled(featEntry.Name)
            Core.SetFeatureEnabled(featEntry.Name, nextVal)
            ApplyCheckboxVisual(rowState)
        end)
    end)

    return cardOverlay, rowState
end

local function PopulateEqolPageLazy(menuState)
    if not menuState or menuState.PagePopulated then return end
    if not (Core.IsValidObj(menuState.Menu) and Core.IsValidObj(menuState.PageVBox)) then return end
    menuState.PagePopulated = true

    local menu = menuState.Menu
    local pc = Core.IsValidObj(menu.PC) and menu.PC or Core.GetLocalPlayerController()
    local outer = Core.GetWidgetOuter(menu)
    local pageVBox = menuState.PageVBox

    local headerTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
    local subTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
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
                subTxt:SetText(Core.MakeText("Click any feature card to enable or disable it. Changes apply immediately and save automatically."))
                if Core.IsValidObj(subTxt.TextBlock) and subTxt.TextBlock.SetColorAndOpacity then
                    subTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.DescText, ColorUseRule = 0 })
                end
            end
        end)
    end
    ApplyHeaderText()
    ExecuteInGameThreadAfterFrames(1, ApplyHeaderText)

    local rows = {}
    menuState.Rows = rows
    for _, featEntry in ipairs(Core.GetToggleableFeatures()) do
        local rowWidget, rowState = BuildFeatureRow(menu, pc, outer, featEntry)
        if Core.IsValidObj(rowWidget) and rowState then
            local rSlot = pageVBox:AddChildToVerticalBox(rowWidget)
            if Core.IsValidObj(rSlot) then
                pcall(function() rSlot:SetPadding({ Left = 0.0, Top = 3.0, Right = 8.0, Bottom = 3.0 }) end)
            end
            rows[#rows + 1] = rowState
        end
    end
end

local function LogCleanTabMetaOnce(refTabBtn)
    if CleanTabMetaLogged or not Core.IsValidObj(refTabBtn) then return end
    CleanTabMetaLogged = true
    local props, funcs = {}, {}
    pcall(function()
        local cls = refTabBtn:GetClass()
        while Core.IsValidObj(cls) do
            local cn = cls:GetFName():ToString()
            if cn == "UserWidget" or cn == "Widget" or cn == "Object" then break end
            cls:ForEachProperty(function(p)
                if #props < 16 then props[#props + 1] = p:GetFName():ToString() end
            end)
            cls:ForEachFunction(function(fn)
                if #funcs < 16 then funcs[#funcs + 1] = fn:GetFName():ToString() end
            end)
            cls = cls:GetSuperStruct()
        end
    end)
    Core.Log(string.format("[EqolSettings] CleanTab cls=%s props=[%s] funcs=[%s]",
        refTabBtn:GetClass():GetFName():ToString(), table.concat(props, ","), table.concat(funcs, ",")))
end

local function HookSiblingTabButtons(menuState)
    if not menuState or not menuState.SiblingTabs then return end
    local btnCls = Core.FindOrLoadClass(PATHS.WBPButtonClass)
    for _, sib in ipairs(menuState.SiblingTabs) do
        if Core.IsValidObj(sib) then
            local sibBtn = FindCleanTabClickButton(sib)
            if Core.IsValidObj(sibBtn) and SafeIsA(sibBtn, btnCls) then
                Core.RegisterWBPButtonClick(sibBtn, function()
                    ExecuteInGameThreadWithDelay(10, function()
                        SetEqolTabVisualActive(menuState, false)
                    end)
                end)
            end
        end
    end
    -- Also hook WBP_SettingsMenu_C's native tab-select or WBP_CleanTab_C's OnClicked if present
    if menuState.SiblingTabs[1] and Core.IsValidObj(menuState.SiblingTabs[1]) then
        local clsPath = nil
        pcall(function()
            local full = menuState.SiblingTabs[1]:GetClass():GetFullName()
            clsPath = full:match("^%S+ (.+)$")
        end)
        if clsPath then
            for _, fnName in ipairs({ "SetSelected", "Select", "OnClicked", "BndEvt__WBP_CleanTab_Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature" }) do
                Core.TryRegisterHook(
                    "EqolSettings_CleanTab_" .. fnName,
                    clsPath .. ":" .. fnName,
                    function(Context)
                        local selfTab = Context:get()
                        if not Core.IsValidObj(selfTab) then return end
                        local selfAddr = selfTab:GetAddress()
                        for _, st in pairs(InjectedMenus) do
                            if st and Core.IsValidObj(st.TabWidget) and st.TabWidget:GetAddress() ~= selfAddr then
                                if Core.IsValidObj(st.Switcher) and st.Switcher.GetActiveWidgetIndex then
                                    ExecuteInGameThreadWithDelay(15, function()
                                        if Core.IsValidObj(st.Switcher) then
                                            local curIdx = tonumber(st.Switcher:GetActiveWidgetIndex())
                                            if curIdx ~= st.EqolIndex then
                                                SetEqolTabVisualActive(st, false)
                                            end
                                        end
                                    end)
                                end
                            end
                        end
                    end
                )
            end
        end
    end
end

local function EnsureEqolSettingsTab(menu)
    if not Core.IsValidObj(menu) then return end
    local menuAddr = menu:GetAddress()
    local existing = InjectedMenus[menuAddr]
    if existing and Core.IsValidObj(existing.TabBtn) and Core.IsValidObj(existing.TabPage) then
        -- Sync active tab highlight in case user switched back to a vanilla tab
        local isEqolActive = false
        if Core.IsValidObj(existing.Switcher) and existing.Switcher.GetActiveWidgetIndex then
            pcall(function()
                isEqolActive = (tonumber(existing.Switcher:GetActiveWidgetIndex()) == existing.EqolIndex)
            end)
        end
        SetEqolTabVisualActive(existing, isEqolActive)
        if existing.PagePopulated then
            SyncAllCheckboxes(existing)
        end
        return
    end

    local switcher, tabBar, refTabBtn, siblingTabs = FindSettingsSwitcherAndTabBar(menu)
    if not (Core.IsValidObj(switcher) and Core.IsValidObj(tabBar)) then
        return
    end

    local pc = Core.IsValidObj(menu.PC) and menu.PC or Core.GetLocalPlayerController()
    local outer = Core.GetWidgetOuter(menu)
    LogCleanTabMetaOnce(refTabBtn)

    -- Create only the lightweight empty ScrollBox shell now (lazy-populate rows on tab click so Esc has 0ms hitch!)
    local pageScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local pageVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    if not (Core.IsValidObj(pageScroll) and Core.IsValidObj(pageVBox)) then
        return
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

    -- Prefer instantiating a real native WBP_CleanTab_C matching refTabBtn so visual styling is 100% identical
    local tabRoot = nil
    local tabWidget = nil
    local tabBtn = nil
    local tabTxt = nil
    local tabLine = nil
    local isNativeCleanTab = false

    if Core.IsValidObj(refTabBtn) then
        local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
        local okCls, tabCls = pcall(function() return refTabBtn:GetClass() end)
        if Core.IsValidObj(wbl) and okCls and Core.IsValidObj(tabCls) then
            local okCreate, nativeTab = pcall(function() return wbl:Create(menu, tabCls, pc) end)
            if okCreate and Core.IsValidObj(nativeTab) then
                isNativeCleanTab = true
                tabWidget = nativeTab
                SetCleanTabLabel(nativeTab, "Eqol")
                ApplyCleanTabState(nativeTab, false)
                ExecuteInGameThreadAfterFrames(1, function()
                    if Core.IsValidObj(nativeTab) then
                        SetCleanTabLabel(nativeTab, "Eqol")
                        ApplyCleanTabState(nativeTab, false)
                    end
                end)

                local btnCls = Core.FindOrLoadClass(PATHS.WBPButtonClass)
                local innerBtn = FindCleanTabClickButton(nativeTab)
                if Core.IsValidObj(innerBtn) and SafeIsA(innerBtn, btnCls) then
                    tabBtn = innerBtn
                    tabRoot = nativeTab
                else
                    -- Overlay a transparent WBP_Button_C over the native WBP_CleanTab_C so clicks are guaranteed hookable
                    local ov = Core.CreateRawWidget(PATHS.OverlayClass, outer)
                    local clickBtn = Core.CreateUserWidget(PATHS.WBPButtonClass, menu, pc)
                    if Core.IsValidObj(ov) and Core.IsValidObj(clickBtn) then
                        pcall(function()
                            if clickBtn.SetBackgroundColour then clickBtn:SetBackgroundColour(COLORS.Transparent) end
                            clickBtn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                            local nSlot = ov:AddChildToOverlay(nativeTab)
                            if Core.IsValidObj(nSlot) then
                                nSlot:SetHorizontalAlignment(0)
                                nSlot:SetVerticalAlignment(0)
                            end
                            local cSlot = ov:AddChildToOverlay(clickBtn)
                            if Core.IsValidObj(cSlot) then
                                cSlot:SetHorizontalAlignment(0)
                                cSlot:SetVerticalAlignment(0)
                            end
                        end)
                        tabBtn = clickBtn
                        tabRoot = ov
                    end
                end
            end
        end
    end

    -- Fallback: custom WBP_CleanTab-styled button if native class creation failed
    if not (Core.IsValidObj(tabRoot) and Core.IsValidObj(tabBtn)) then
        isNativeCleanTab = false
        local tabOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
        tabBtn = Core.CreateUserWidget(PATHS.WBPButtonClass, menu, pc)
        local tabVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
        tabTxt = Core.CreateUserWidget(PATHS.WBPTextClass, menu, pc)
        local tabLineSize = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
        tabLine = Core.CreateRawWidget(PATHS.BorderClass, outer)
        if not (Core.IsValidObj(tabOverlay) and Core.IsValidObj(tabBtn) and Core.IsValidObj(tabVBox)
            and Core.IsValidObj(tabTxt) and Core.IsValidObj(tabLineSize) and Core.IsValidObj(tabLine)) then
            return
        end
        tabRoot = tabOverlay
        tabWidget = tabOverlay

        pcall(function()
            if tabBtn.SetBackgroundColour then tabBtn:SetBackgroundColour(COLORS.Transparent) end
            tabBtn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })

            tabVBox:SetVisibility(3)
            local tSlot = tabVBox:AddChildToVerticalBox(tabTxt)
            if Core.IsValidObj(tSlot) then
                tSlot:SetHorizontalAlignment(2)
                tSlot:SetVerticalAlignment(2)
                tSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                tSlot:SetPadding({ Left = 8.0, Top = 6.0, Right = 8.0, Bottom = 6.0 })
            end

            tabLineSize:SetHeightOverride(2.0)
            tabLineSize:SetVisibility(3)
            tabLine:SetBrushColor(COLORS.TabLineInactive)
            tabLine:SetVisibility(3)
            tabLineSize:AddChild(tabLine)
            local lSlot = tabVBox:AddChildToVerticalBox(tabLineSize)
            if Core.IsValidObj(lSlot) then
                lSlot:SetHorizontalAlignment(0)
                lSlot:SetVerticalAlignment(3)
            end

            local bSlot = tabOverlay:AddChildToOverlay(tabBtn)
            if Core.IsValidObj(bSlot) then
                bSlot:SetHorizontalAlignment(0)
                bSlot:SetVerticalAlignment(0)
            end
            local vSlot = tabOverlay:AddChildToOverlay(tabVBox)
            if Core.IsValidObj(vSlot) then
                vSlot:SetHorizontalAlignment(0)
                vSlot:SetVerticalAlignment(0)
            end
        end)

        local function ApplyTabLabel()
            pcall(function()
                tabTxt:SetVisibility(3)
                tabTxt:SetSize(13)
                tabTxt:SetText(Core.MakeText("Eqol"))
                if Core.IsValidObj(tabTxt.TextBlock) then
                    tabTxt.TextBlock:SetVisibility(3)
                    tabTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.TabTextInactive, ColorUseRule = 0 })
                end
            end)
        end
        ApplyTabLabel()
        ExecuteInGameThreadAfterFrames(1, ApplyTabLabel)
    end

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
            addedSlot = tabBar:AddChildToGrid(tabRoot, targetRow, targetCol)
            if tabBar.SetColumnFill then
                tabBar:SetColumnFill(targetCol, 1.0)
            end
        elseif tabBar.AddChildToHorizontalBox then
            addedSlot = tabBar:AddChildToHorizontalBox(tabRoot)
        elseif tabBar.AddChildToVerticalBox then
            addedSlot = tabBar:AddChildToVerticalBox(tabRoot)
        else
            addedSlot = tabBar:AddChild(tabRoot)
        end
    end)

    if Core.IsValidObj(addedSlot) and Core.IsValidObj(refTabBtn) and Core.IsValidObj(refTabBtn.Slot) then
        pcall(function()
            addedSlot:SetPadding(refTabBtn.Slot.Padding)
            addedSlot:SetHorizontalAlignment(0)
            addedSlot:SetVerticalAlignment(refTabBtn.Slot.VerticalAlignment)
        end)
    end

    local menuState = {
        Menu             = menu,
        Switcher         = switcher,
        EqolIndex        = eqolIdx,
        TabBtn           = tabBtn,
        TabWidget        = tabWidget,
        IsNativeCleanTab = isNativeCleanTab,
        TabTxt           = tabTxt,
        TabLine          = tabLine,
        TabPage          = pageScroll,
        PageVBox         = pageVBox,
        SiblingTabs      = siblingTabs,
        PagePopulated    = false,
        Rows             = {},
    }
    InjectedMenus[menuAddr] = menuState
    HookSiblingTabButtons(menuState)

    Core.RegisterWBPButtonClick(tabBtn, function()
        ExecuteInGameThreadWithDelay(10, function()
            if Core.IsValidObj(switcher) and Core.IsValidObj(pageScroll) then
                PopulateEqolPageLazy(menuState)
                pcall(function()
                    if switcher.SetActiveWidget then
                        switcher:SetActiveWidget(pageScroll)
                    else
                        switcher:SetActiveWidgetIndex(eqolIdx)
                    end
                end)
                SetEqolTabVisualActive(menuState, true)
                SyncAllCheckboxes(menuState)
            end
        end)
    end)
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
