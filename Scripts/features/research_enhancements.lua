-- Eqol Feature: Research Screen Search Bar & Queue Drag-and-Drop Reorder
-- Injects a native-styled search bar into the Research screen (matching Help Menu / Codex)
-- and allows dragging queued research items with the mouse to change queue order.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "ResearchEnhancements",
}

local PATHS = {
    ResearchTreeClass           = "/Game/Blueprints/Widgets/Windows/WBP_ResearchTree_2.WBP_ResearchTree_2_C",
    ResearchListClass           = "/Game/Blueprints/Widgets/Display/Research/WBP_ResearchList.WBP_ResearchList_C",
    ResearchTechnologyClass     = "/Game/Blueprints/Widgets/Display/Research/WBP_ResearchTechnology.WBP_ResearchTechnology_C",
    ResearchTechnologyWideClass = "/Game/Blueprints/Widgets/Display/Research/WBP_ResearchTechnologyWide.WBP_ResearchTechnologyWide_C",
    TextInputClass              = "/Game/Blueprints/Widgets/Basic/WBP_TextInput.WBP_TextInput_C",
    VerticalBoxClass            = Core.PATHS.VerticalBoxClass,
    SizeBoxClass                = Core.PATHS.SizeBoxClass,
}

local InjectedTrees = {} -- treeAddr -> state
local InputToTree   = {} -- textInputAddr -> state
local ListToTree    = {} -- researchListAddr -> state
local ActiveDrag    = nil

local EnsureResearchSearchBar -- forward declaration

local function SafeTextToString(val)
    if val == nil then return "" end
    if type(val) == "string" then return val end
    local ok, str = pcall(function()
        if val.ToString then
            return val:ToString()
        end
        return nil
    end)
    if ok and type(str) == "string" then
        return str
    end
    return ""
end

local function ContainsQuery(text, queryLower)
    if queryLower == "" then return true end
    if type(text) ~= "string" or text == "" then return false end
    return string.find(string.lower(text), queryLower, 1, true) ~= nil
end

local function ObjectMatchesQuery(obj, queryLower)
    obj = Core.UnwrapArrayElem(obj)
    if not Core.IsValidObj(obj) then return false end

    local okName, fName = pcall(function() return obj:GetFName():ToString() end)
    if okName and ContainsQuery(fName, queryLower) then
        return true
    end

    local okDisp, dispVal = pcall(function() return obj.DisplayName end)
    if okDisp and ContainsQuery(SafeTextToString(dispVal), queryLower) then
        return true
    end

    -- Check CDO DisplayName when obj is a UClass
    local okFull, full = pcall(function() return obj:GetFullName() end)
    if okFull and type(full) == "string" then
        local objPath = full:match("^%S+ (.+)$") or full
        local pkg, clsName = objPath:match("^(.-)%.([^.]+)$")
        if pkg and clsName and string.sub(clsName, 1, 9) ~= "Default__" then
            local cdo = Core.GetCDO(pkg .. ".Default__" .. clsName)
            if Core.IsValidObj(cdo) then
                local okCdoDisp, cdoDisp = pcall(function() return cdo.DisplayName end)
                if okCdoDisp and ContainsQuery(SafeTextToString(cdoDisp), queryLower) then
                    return true
                end
            end
        end
    end

    return false
end

local function TechMatchesQuery(tech, queryLower)
    if queryLower == "" then return true end
    if not Core.IsValidObj(tech) then return false end

    local okDisp, dispVal = pcall(function() return tech.DisplayName end)
    if okDisp and ContainsQuery(SafeTextToString(dispVal), queryLower) then
        return true
    end

    local okDesc, descVal = pcall(function() return tech.Description end)
    if okDesc and ContainsQuery(SafeTextToString(descVal), queryLower) then
        return true
    end

    local okUnlocks, unlocks = pcall(function() return tech.Unlocks end)
    if okUnlocks and unlocks then
        local matchedUnlock = false
        local unlockFields = { "Block", "Recipe", "Item", "Buildable" }
        StationData.ForEachArray(unlocks, function(_, elem)
            if matchedUnlock then return end
            local unlock = elem
            if unlock ~= nil and type(unlock.get) == "function" then
                local okGet, inner = pcall(function() return unlock:get() end)
                if okGet and inner ~= nil then unlock = inner end
            end
            if not unlock then return end

            local okUDisp, uDisp = pcall(function() return unlock.DisplayName end)
            if okUDisp and ContainsQuery(SafeTextToString(uDisp), queryLower) then
                matchedUnlock = true
                return
            end

            for _, fieldName in ipairs(unlockFields) do
                local okField, ref = pcall(function() return unlock[fieldName] end)
                if okField and ref ~= nil and ObjectMatchesQuery(ref, queryLower) then
                    matchedUnlock = true
                    return
                end
            end
        end)
        if matchedUnlock then
            return true
        end
    end

    return ObjectMatchesQuery(tech, queryLower)
end

local function ResolveTechFromWidget(widget)
    if not Core.IsValidObj(widget) then return nil end
    local tech = nil
    pcall(function() tech = Core.UnwrapArrayElem(widget.Technology) end)
    if Core.IsValidObj(tech) then return tech end
    pcall(function()
        if widget.Research ~= nil then
            tech = Core.UnwrapArrayElem(widget.Research.Technology)
        end
    end)
    return Core.IsValidObj(tech) and tech or nil
end

local function ReadSearchQuery(st)
    if not st or not Core.IsValidObj(st.SearchInput) then return "" end
    local raw = nil
    pcall(function()
        if Core.IsValidObj(st.SearchInput.EditableTextBox_80) then
            raw = SafeTextToString(st.SearchInput.EditableTextBox_80:GetText())
        end
    end)
    if raw == nil or raw == "" then
        pcall(function()
            if st.SearchInput.GetText then
                raw = SafeTextToString(st.SearchInput:GetText())
            end
        end)
    end
    return type(raw) == "string" and raw or ""
end

local function SetWideTreeDimming(tree, queryLower)
    if not Core.IsValidObj(tree) then return end

    local updatedAny = false
    local treeView = nil
    pcall(function() treeView = tree.ResearchTreeView end)
    if Core.IsValidObj(treeView) then
        local okLV, lvWidgets = pcall(function() return treeView.ListViewWidgets end)
        if okLV and lvWidgets then
            StationData.ForEachArray(lvWidgets, function(_, elem)
                local w = Core.UnwrapArrayElem(elem)
                if not Core.IsValidObj(w) then return end
                updatedAny = true
                local tech = ResolveTechFromWidget(w)
                local matched = (queryLower == "") or TechMatchesQuery(tech, queryLower)
                pcall(function() w:SetRenderOpacity(matched and 1.0 or 0.22) end)
            end)
        end
    end

    if not updatedAny then
        local okAll, wideWidgets = pcall(FindAllOf, "WBP_ResearchTechnologyWide_C")
        if okAll and wideWidgets then
            for _, w in ipairs(wideWidgets) do
                if Core.IsValidObj(w) then
                    local tech = ResolveTechFromWidget(w)
                    local matched = (queryLower == "") or TechMatchesQuery(tech, queryLower)
                    pcall(function() w:SetRenderOpacity(matched and 1.0 or 0.22) end)
                end
            end
        end
    end
end

local function ApplyResearchFilter(st, overrideQuery)
    if not st or not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.ResearchList) then
        return
    end

    local rawText = (type(overrideQuery) == "string") and overrideQuery or ReadSearchQuery(st)
    local trimmed = rawText:match("^%s*(.-)%s*$") or ""
    local queryLower = string.lower(trimmed)

    local treeView = nil
    pcall(function() treeView = st.Tree.ResearchTreeView end)

    local container = nil
    pcall(function() container = st.ResearchList.Container end)
    if Core.IsValidObj(container) then
        pcall(function()
            local count = container:GetChildrenCount()
            for i = 0, count - 1 do
                local child = container:GetChildAt(i)
                if Core.IsValidObj(child) then
                    local tech = ResolveTechFromWidget(child)
                    local matched = (queryLower == "") or TechMatchesQuery(tech, queryLower)
                    child:SetVisibility(matched and 0 or 1) -- 0 = Visible, 1 = Collapsed

                    if Core.IsValidObj(treeView) and Core.IsValidObj(tech) and treeView.GetWidget then
                        local okW, wideW = pcall(function() return treeView:GetWidget(tech) end)
                        if okW and Core.IsValidObj(wideW) then
                            pcall(function() wideW:SetRenderOpacity(matched and 1.0 or 0.22) end)
                        end
                    end
                end
            end
        end)
    end

    SetWideTreeDimming(st.Tree, queryLower)
end

EnsureResearchSearchBar = function(tree)
    Feature.RegisterHooks()
    if not Core.IsValidObj(tree) then return nil end

    local treeAddr = tree:GetAddress()
    local existing = InjectedTrees[treeAddr]
    if existing and Core.IsValidObj(existing.SearchInput) and Core.IsValidObj(existing.ResearchList) then
        return existing
    end

    local rList = nil
    pcall(function() rList = tree.WBP_ResearchList end)
    if not Core.IsValidObj(rList) then return nil end

    local scrollBox = nil
    pcall(function() scrollBox = rList.ScrollBox_63 end)
    if not Core.IsValidObj(scrollBox) then return nil end

    local sizeBox = nil
    pcall(function() sizeBox = scrollBox:GetParent() end)
    if not Core.IsValidObj(sizeBox) then return nil end

    -- Avoid double-wrapping if ScrollBox_63 is already inside an injected VerticalBox
    local okCls, parentCls = pcall(function() return sizeBox:GetClass():GetFName():ToString() end)
    if okCls and parentCls == "VerticalBox" then
        local existingInput = nil
        pcall(function()
            local count = sizeBox:GetChildrenCount()
            for i = 0, count - 1 do
                local ch = sizeBox:GetChildAt(i)
                if Core.IsValidObj(ch) and ch.GetChildrenCount and ch:GetChildrenCount() > 0 then
                    local inner = ch:GetChildAt(0)
                    if Core.IsValidObj(inner) and Core.IsValidObj(inner.EditableTextBox_80) then
                        existingInput = inner
                        break
                    end
                end
            end
        end)
        if Core.IsValidObj(existingInput) then
            local st = {
                Tree = tree,
                ResearchList = rList,
                SearchInput = existingInput,
            }
            InjectedTrees[treeAddr] = st
            InputToTree[existingInput:GetAddress()] = st
            ListToTree[rList:GetAddress()] = st
            Core.RegisterTextInput(existingInput, tree)
            return st
        end
        return nil
    end

    local outer = Core.GetWidgetOuter(rList)
    local okPC, owningPC = pcall(function() return tree:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local vBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local searchSizeBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local searchInput = Core.CreateUserWidget(PATHS.TextInputClass, tree, pc)
    if not (Core.IsValidObj(vBox) and Core.IsValidObj(searchSizeBox) and Core.IsValidObj(searchInput)) then
        return nil
    end

    pcall(function()
        sizeBox:SetHeightOverride(304.0)
        searchSizeBox:SetHeightOverride(38.0)
        searchInput.Size = 13.0
        searchInput["Minimum Width"] = 220.0
    end)

    local sInSlot = searchSizeBox:AddChild(searchInput)
    if Core.IsValidObj(sInSlot) then
        pcall(function()
            sInSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            sInSlot:SetVerticalAlignment(0)   -- VAlign_Fill
        end)
    end

    pcall(function() scrollBox:RemoveFromParent() end)
    pcall(function()
        if sizeBox.GetChildrenCount and sizeBox:GetChildrenCount() > 0 and sizeBox.ClearChildren then
            sizeBox:ClearChildren()
        end
    end)

    local rootSlot = sizeBox:AddChild(vBox)
    if Core.IsValidObj(rootSlot) then
        pcall(function()
            rootSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            rootSlot:SetVerticalAlignment(0)   -- VAlign_Fill
        end)
    end

    local sSlot = vBox:AddChildToVerticalBox(searchSizeBox)
    if Core.IsValidObj(sSlot) then
        pcall(function()
            sSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            sSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 6.0 })
        end)
    end

    local sbSlot = vBox:AddChildToVerticalBox(scrollBox)
    if Core.IsValidObj(sbSlot) then
        pcall(function()
            sbSlot:SetSize({ Value = 1.0, SizeRule = 1 }) -- Fill
            sbSlot:SetHorizontalAlignment(0)               -- HAlign_Fill
            sbSlot:SetVerticalAlignment(0)                 -- VAlign_Fill
        end)
    end

    pcall(function()
        if Core.IsValidObj(searchInput.EditableTextBox_80) then
            searchInput.EditableTextBox_80:SetHintText(Core.MakeText("Search research..."))
            searchInput.EditableTextBox_80:SetText(Core.MakeText(""))
            searchInput.EditableTextBox_80.MinimumDesiredWidth = 220.0
        elseif searchInput.SetText then
            searchInput:SetText(Core.MakeText(""))
        end
    end)

    local st = {
        Tree = tree,
        ResearchList = rList,
        SearchInput = searchInput,
    }
    InjectedTrees[treeAddr] = st
    InputToTree[searchInput:GetAddress()] = st
    ListToTree[rList:GetAddress()] = st
    Core.RegisterTextInput(searchInput, tree)
    return st
end

local function EnsureAndFilterTree(tree)
    if not Core.IsValidObj(tree) then return end
    local st = EnsureResearchSearchBar(tree)
    if st then
        ApplyResearchFilter(st)
    end
end

local function ResolveTreeForList(rList)
    if not Core.IsValidObj(rList) then return nil end
    local rAddr = rList:GetAddress()
    local cached = ListToTree[rAddr]
    if cached and Core.IsValidObj(cached.Tree) then
        return cached.Tree
    end
    local okTrees, trees = pcall(FindAllOf, "WBP_ResearchTree_2_C")
    if okTrees and trees then
        for _, tree in ipairs(trees) do
            if Core.IsValidObj(tree) and Core.IsValidObj(tree.WBP_ResearchList) then
                if tree.WBP_ResearchList:GetAddress() == rAddr then
                    return tree
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Queue Drag-and-Drop Reordering
--------------------------------------------------------------------------------

local function GetMouseViewportPos(pc)
    local layoutLib = Core.GetCDO(Core.PATHS.WidgetLayoutLibCDO)
    if Core.IsValidObj(layoutLib) and Core.IsValidObj(pc) then
        local okVP, pos = pcall(function()
            return layoutLib:GetMousePositionOnViewport(pc)
        end)
        if okVP and pos and type(pos.X) == "number" and type(pos.Y) == "number" then
            return pos.X, pos.Y
        end
    end
    if Core.IsValidObj(pc) then
        local okMP, res, x, y = pcall(function() return pc:GetMousePosition() end)
        if okMP and type(res) == "number" and type(x) == "number" then
            return res, x
        end
        if okMP and type(x) == "number" and type(y) == "number" then
            return x, y
        end
    end
    return nil, nil
end

local function ResetQueueChildVisuals(queueBox, deferredVisibilityWidget)
    if Core.IsValidObj(queueBox) then
        pcall(function()
            local count = queueBox:GetChildrenCount()
            for i = 0, count - 1 do
                local ch = queueBox:GetChildAt(i)
                if Core.IsValidObj(ch) then
                    ch:SetRenderOpacity(1.0)
                    ch:SetRenderTranslation({ X = 0.0, Y = 0.0 })
                    if not deferredVisibilityWidget or ch:GetAddress() ~= deferredVisibilityWidget:GetAddress() then
                        ch:SetVisibility(0)
                    end
                end
            end
        end)
    end
    if Core.IsValidObj(deferredVisibilityWidget) then
        ExecuteInGameThreadWithDelay(1, function()
            if Core.IsValidObj(deferredVisibilityWidget) then
                pcall(function() deferredVisibilityWidget:SetVisibility(0) end)
            end
        end)
    end
end

local function CollectQueuedTechs(tree, queueBox)
    local techs = {}
    pcall(function()
        local count = queueBox:GetChildrenCount()
        for i = 0, count - 1 do
            local ch = queueBox:GetChildAt(i)
            techs[i + 1] = ResolveTechFromWidget(ch)
        end
    end)

    -- Fallback via ResearchState if any slot lacked a direct Technology pointer
    local rState = nil
    pcall(function() rState = tree.ResearchState end)
    if Core.IsValidObj(rState) then
        local okAllRes, allRes = pcall(function() return rState.Research end)
        local okQIdx, qIndices = pcall(function() return rState.ResearchQueueIndices end)
        if okAllRes and allRes and okQIdx and qIndices then
            local queueFromState = {}
            StationData.ForEachArray(qIndices, function(_, elem)
                local idx = tonumber(elem)
                if not idx and elem ~= nil and type(elem.get) == "function" then
                    pcall(function() idx = tonumber(elem:get()) end)
                end
                if idx ~= nil then
                    pcall(function()
                        local entry = allRes[idx + 1]
                        if entry ~= nil and type(entry.get) == "function" then
                            entry = entry:get()
                        end
                        local t = entry and Core.UnwrapArrayElem(entry.Technology) or nil
                        table.insert(queueFromState, t)
                    end)
                end
            end)
            for i = 1, #techs do
                if not Core.IsValidObj(techs[i]) and Core.IsValidObj(queueFromState[i]) then
                    techs[i] = queueFromState[i]
                end
            end
        end
    end

    return techs
end

local function ReorderResearchQueue(tree, fromIdx, toIdx)
    if not Core.IsValidObj(tree) or fromIdx == toIdx then return end
    local queueBox = nil
    pcall(function() queueBox = tree.ResearchQueueContainer end)
    if not Core.IsValidObj(queueBox) then return end

    local oldTechs = CollectQueuedTechs(tree, queueBox)
    local count = #oldTechs
    if count < 2 or fromIdx < 1 or fromIdx > count or toIdx < 1 or toIdx > count then
        return
    end
    for i = 1, count do
        if not Core.IsValidObj(oldTechs[i]) then
            return
        end
    end

    local newTechs = {}
    for i = 1, count do
        newTechs[i] = oldTechs[i]
    end
    local moved = table.remove(newTechs, fromIdx)
    table.insert(newTechs, toIdx, moved)

    local origSelected = nil
    local origShouldAdd = false
    pcall(function()
        origSelected = tree.SelectedTechnology
        origShouldAdd = tree.ShouldAdd == true
    end)

    local firstChanged = math.min(fromIdx, toIdx)
    for i = count, firstChanged, -1 do
        pcall(function()
            tree.SelectedTechnology = oldTechs[i]
            tree.ShouldAdd = false
            tree:QueueResearch()
        end)
    end
    for i = firstChanged, count do
        pcall(function()
            tree.SelectedTechnology = newTechs[i]
            tree.ShouldAdd = true
            tree:QueueResearch()
        end)
    end

    pcall(function()
        tree.SelectedTechnology = origSelected
        tree.ShouldAdd = origShouldAdd
        if tree.RefreshResearchQueue then tree:RefreshResearchQueue() end
        if tree.RefreshQueueButton then tree:RefreshQueueButton() end
    end)

    ExecuteInGameThreadWithDelay(20, function()
        if Core.IsValidObj(tree) then
            pcall(function()
                if tree.RefreshResearchQueue then tree:RefreshResearchQueue() end
                if tree.RefreshQueueButton then tree:RefreshQueueButton() end
            end)
        end
    end)
end

local function FindOwningTreeForQueueParent(parentWidget)
    if not Core.IsValidObj(parentWidget) then return nil, nil end
    local pAddr = parentWidget:GetAddress()

    for _, st in pairs(InjectedTrees) do
        if Core.IsValidObj(st.Tree) and Core.IsValidObj(st.Tree.ResearchQueueContainer) then
            if st.Tree.ResearchQueueContainer:GetAddress() == pAddr then
                return st.Tree, st.Tree.ResearchQueueContainer
            end
        end
    end

    local okTrees, trees = pcall(FindAllOf, "WBP_ResearchTree_2_C")
    if okTrees and trees then
        for _, tree in ipairs(trees) do
            if Core.IsValidObj(tree) and Core.IsValidObj(tree.ResearchQueueContainer) then
                if tree.ResearchQueueContainer:GetAddress() == pAddr then
                    return tree, tree.ResearchQueueContainer
                end
            end
        end
    end
    return nil, nil
end

local function StartQueueDrag(tree, queueBox, dragWidget, startIdx, count)
    if ActiveDrag then return end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local startX, startY = GetMouseViewportPos(pc)
    if not startX or not startY then return end

    local dragState = {
        Tree = tree,
        QueueBox = queueBox,
        DragWidget = dragWidget,
        StartIdx = startIdx,
        TargetIdx = startIdx,
        Count = count,
        IsDragging = false,
        StartX = startX,
        StartY = startY,
    }
    ActiveDrag = dragState

    local function DragPoll()
        if ActiveDrag ~= dragState then return end

        local treeOk = Core.IsValidObj(dragState.Tree)
            and Core.IsValidObj(dragState.QueueBox)
            and Core.IsValidObj(dragState.DragWidget)
        local mouseDown = false
        if Core.IsValidObj(pc) then
            local okDown, down = pcall(function()
                return pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") })
            end)
            mouseDown = okDown and down == true
        end

        local treeVisible = false
        if treeOk then
            local okVis, vis = pcall(function() return dragState.Tree:IsVisible() end)
            treeVisible = okVis and vis == true
        end

        if not treeOk or not treeVisible or not mouseDown then
            ActiveDrag = nil
            local wasDragging = dragState.IsDragging
            local fromIdx = dragState.StartIdx
            local toIdx = dragState.TargetIdx
            ResetQueueChildVisuals(dragState.QueueBox, wasDragging and dragState.DragWidget or nil)
            if treeOk and wasDragging and toIdx ~= fromIdx then
                ReorderResearchQueue(dragState.Tree, fromIdx, toIdx)
            end
            return
        end

        local curX, curY = GetMouseViewportPos(pc)
        if curX and curY then
            local dx = curX - dragState.StartX
            local dy = curY - dragState.StartY
            if not dragState.IsDragging and (dx * dx + dy * dy) > 25.0 then
                dragState.IsDragging = true
                -- Make dragged item HitTestInvisible while moving so siblings beneath can hover and Button won't fire OnClicked on drop
                pcall(function() dragState.DragWidget:SetVisibility(3) end)
            end

            if dragState.IsDragging then
                local hoveredIdx = nil
                pcall(function()
                    local qCount = dragState.QueueBox:GetChildrenCount()
                    for i = 0, qCount - 1 do
                        local slotIdx = i + 1
                        if slotIdx ~= dragState.StartIdx then
                            local ch = dragState.QueueBox:GetChildAt(i)
                            if Core.IsValidObj(ch) and ch.IsHovered and ch:IsHovered() == true then
                                hoveredIdx = slotIdx
                                break
                            end
                        end
                    end
                end)

                if hoveredIdx then
                    dragState.TargetIdx = hoveredIdx
                else
                    local slotDelta = math.floor((dx + 28.0) / 56.0)
                    dragState.TargetIdx = Core.Clamp(dragState.StartIdx + slotDelta, 1, dragState.Count)
                end

                pcall(function()
                    local qCount = dragState.QueueBox:GetChildrenCount()
                    for i = 0, qCount - 1 do
                        local slotIdx = i + 1
                        local ch = dragState.QueueBox:GetChildAt(i)
                        if Core.IsValidObj(ch) then
                            if slotIdx == dragState.StartIdx then
                                ch:SetRenderOpacity(0.45)
                                ch:SetRenderTranslation({ X = dx, Y = dy })
                            elseif slotIdx == dragState.TargetIdx and dragState.TargetIdx ~= dragState.StartIdx then
                                ch:SetRenderOpacity(0.75)
                                ch:SetRenderTranslation({ X = 0.0, Y = -4.0 })
                            else
                                ch:SetRenderOpacity(1.0)
                                ch:SetRenderTranslation({ X = 0.0, Y = 0.0 })
                            end
                        end
                    end
                end)
            end
        end

        ExecuteInGameThreadWithDelay(16, DragPoll)
    end

    ExecuteInGameThreadWithDelay(16, DragPoll)
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_ResearchTree_2_C = function(tree)
        Feature.RegisterHooks()
        ExecuteInGameThreadWithDelay(60, function()
            EnsureAndFilterTree(tree)
        end)
    end,
}

function Feature.RegisterHooks()
    local treeHookFns = {
        "SetupWidget",
        "Refresh",
        "OnResearchCompleted",
        "SetFilter",
    }
    for _, fnName in ipairs(treeHookFns) do
        Core.TryRegisterHook(
            "ResearchEnhancements_" .. fnName,
            PATHS.ResearchTreeClass .. ":" .. fnName,
            function(Context)
                local tree = Context:get()
                if Core.IsValidObj(tree) then
                    ExecuteInGameThreadWithDelay(30, function()
                        EnsureAndFilterTree(tree)
                    end)
                end
            end
        )
    end

    Core.TryRegisterHook(
        "ResearchEnhancements_RefreshList",
        PATHS.ResearchListClass .. ":RefreshList",
        function(Context)
            local rList = Context:get()
            if Core.IsValidObj(rList) then
                ExecuteInGameThreadWithDelay(20, function()
                    local tree = ResolveTreeForList(rList)
                    if Core.IsValidObj(tree) then
                        EnsureAndFilterTree(tree)
                    end
                end)
            end
        end
    )

    Core.TryRegisterHook(
        "ResearchEnhancements_OnTextChanged",
        PATHS.TextInputClass .. ":BndEvt__WBP_TextInput_EditableTextBox_80_K2Node_ComponentBoundEvent_0_OnEditableTextBoxChangedEvent__DelegateSignature",
        function(Context, textParam)
            local inputWidget = Context:get()
            if not Core.IsValidObj(inputWidget) then return end
            local st = InputToTree[inputWidget:GetAddress()]
            if not st then return end

            local override = nil
            pcall(function()
                local raw = (textParam and type(textParam.get) == "function") and textParam:get() or textParam
                if type(raw) == "string" or (raw ~= nil and raw.ToString) then
                    override = SafeTextToString(raw)
                end
            end)
            ApplyResearchFilter(st, override)
        end
    )

    Core.TryRegisterHook(
        "ResearchEnhancements_OnTechButtonPressed",
        PATHS.ResearchTechnologyClass .. ":BndEvt__WBP_ResearchTechnology_Button_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local widget = Context:get()
            if not Core.IsValidObj(widget) then return end

            local parent = nil
            pcall(function() parent = widget:GetParent() end)
            local tree, queueBox = FindOwningTreeForQueueParent(parent)
            if not (Core.IsValidObj(tree) and Core.IsValidObj(queueBox)) then return end

            local count = 0
            local startIdx = nil
            pcall(function()
                count = queueBox:GetChildrenCount()
                local targetAddr = widget:GetAddress()
                for i = 0, count - 1 do
                    local ch = queueBox:GetChildAt(i)
                    if Core.IsValidObj(ch) and ch:GetAddress() == targetAddr then
                        startIdx = i + 1
                        break
                    end
                end
            end)

            if startIdx and count > 1 then
                StartQueueDrag(tree, queueBox, widget, startIdx, count)
            end
        end
    )
end

function Feature.OnClientRestart()
    Feature.RegisterHooks()
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedTrees) do
        if not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.SearchInput) then
            InjectedTrees[addr] = nil
        end
    end
    for inputAddr, st in pairs(InputToTree) do
        if not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.SearchInput) then
            InputToTree[inputAddr] = nil
        end
    end
    for listAddr, st in pairs(ListToTree) do
        if not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.ResearchList) then
            ListToTree[listAddr] = nil
        end
    end
end

function Feature.Init()
    Feature.RegisterHooks()
end

return Feature
