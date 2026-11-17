-- Eqol Feature: Assembler UI Input Rate Display
-- Displays required input item rates (items/min) on the right side of the
-- Crafting header panel inside WBP_Assembler_C and WBP_ShipAssembler_C.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "AssemblerInputRates",
}

local PATHS = {
    AssemblerObjClass  = "/Script/MainSequence.AssemblerObject",
    RecipeClass        = "/Script/MainSequence.Recipe",
    HorizontalBoxClass = "/Script/UMG.HorizontalBox",
    VerticalBoxClass   = "/Script/UMG.VerticalBox",
    OverlayClass       = "/Script/UMG.Overlay",
    BorderClass        = "/Script/UMG.Border",
    SizeBoxClass       = "/Script/UMG.SizeBox",
    SpacerClass        = "/Script/UMG.Spacer",
    GridPanelClass     = "/Script/UMG.GridPanel",
    UserWidgetClass    = "/Script/UMG.UserWidget",
    WBPTextClass       = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass       = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
}

local COLORS = {
    LabelMuted = { R = 0.85, G = 0.87, B = 0.90, A = 0.95 },
    WhiteText  = { R = 0.96, G = 0.97, B = 0.99, A = 1.00 },
    RateTint   = { R = 0.92, G = 0.94, B = 0.97, A = 1.00 },
    SlotBg     = { R = 0.14, G = 0.15, B = 0.17, A = 0.70 },
}

local InjectedAssemblers = {} -- widgetAddr -> state
local ClassPropCache     = {} -- clsAddr -> { MachProps = {...}, RecProps = {...}, Logged = bool }
local LoggedDiag         = {}
local PollActive         = false
local RefreshAssemblerWidget -- forward declaration

local function SafeName(obj)
    if not Core.IsValidObj(obj) then return "nil" end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return (ok and type(n) == "string") and n or "?"
end

local function SafeClassName(obj)
    if not Core.IsValidObj(obj) then return "nil" end
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return (ok and type(n) == "string") and n or "?"
end

local function ReadWidgetText(w)
    if not Core.IsValidObj(w) then return nil end
    local s = nil
    pcall(function()
        if Core.IsValidObj(w.TextBlock) and w.TextBlock.GetText then
            s = w.TextBlock:GetText():ToString()
        elseif w.GetText then
            s = w:GetText():ToString()
        end
    end)
    if type(s) == "string" and s ~= "" then
        return s
    end
    return nil
end

local function FormatRate(rate)
    local r = tonumber(rate) or 0.0
    local rounded = math.floor(r + 0.5)
    if math.abs(r - rounded) < 0.05 then
        return string.format("%d / min", rounded)
    end
    return string.format("%.1f / min", r)
end

local function GetItemDisplayName(item)
    if not Core.IsValidObj(item) then return "Item" end
    for _, prop in ipairs({ "DisplayName", "Name", "ItemName", "Title" }) do
        local ok, v = pcall(function() return item[prop] end)
        if ok and v ~= nil then
            local okS, s = pcall(function()
                return type(v) == "string" and v or v:ToString()
            end)
            if okS and type(s) == "string" and s ~= "" and not s:match("^FText ") then
                return s
            end
        end
    end
    return SafeName(item):gsub("^ITEM_", ""):gsub("_", " ")
end

local function GetRefFontSize(refWbpText, defaultSz)
    local sz = nil
    if Core.IsValidObj(refWbpText) then
        local refTB = Core.IsValidObj(refWbpText.TextBlock) and refWbpText.TextBlock or refWbpText
        pcall(function()
            if refTB and refTB.Font and refTB.Font.Size then
                local n = tonumber(refTB.Font.Size)
                if n and n > 0 then sz = n end
            end
        end)
    end
    return sz or defaultSz
end

local function CopyTextStyle(dstWbpText, refWbpText, maxOrExactSize, fallbackColor)
    if not Core.IsValidObj(dstWbpText) then return end
    local dstTB = Core.IsValidObj(dstWbpText.TextBlock) and dstWbpText.TextBlock or dstWbpText
    local refTB = (Core.IsValidObj(refWbpText) and Core.IsValidObj(refWbpText.TextBlock)) and refWbpText.TextBlock or refWbpText

    pcall(function()
        if Core.IsValidObj(refTB) and refTB.Font and dstTB.SetFont then
            dstTB:SetFont(refTB.Font)
        end
    end)
    local targetSz = GetRefFontSize(refWbpText, maxOrExactSize or 11)
    if maxOrExactSize and targetSz > maxOrExactSize then
        targetSz = maxOrExactSize
    end
    if dstWbpText.SetSize then
        pcall(function() dstWbpText:SetSize(targetSz) end)
    end
    pcall(function()
        if dstTB.SetColorAndOpacity then
            local col = fallbackColor
            if not col and Core.IsValidObj(refTB) and refTB.ColorAndOpacity and refTB.ColorAndOpacity.SpecifiedColor then
                col = refTB.ColorAndOpacity.SpecifiedColor
            end
            if col then
                dstTB:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
            end
        end
    end)
end

local function WalkWidgetTree(rootWidget)
    local list = {}
    local visited = {}
    local function Visit(w, depth)
        if not Core.IsValidObj(w) or depth > 14 then return end
        local addr = w:GetAddress()
        if visited[addr] then return end
        visited[addr] = true
        list[#list + 1] = w

        local okCnt, cnt = pcall(function()
            return w.GetChildrenCount and w:GetChildrenCount() or 0
        end)
        if okCnt and type(cnt) == "number" and cnt > 0 then
            for i = 0, cnt - 1 do
                local okCh, ch = pcall(function() return w:GetChildAt(i) end)
                if okCh and Core.IsValidObj(ch) then
                    Visit(ch, depth + 1)
                end
            end
        end
        if w.GetContent then
            local okCon, con = pcall(function() return w:GetContent() end)
            if okCon and Core.IsValidObj(con) then
                Visit(con, depth + 1)
            end
        end
        if Core.IsValidObj(w.WidgetTree) and Core.IsValidObj(w.WidgetTree.RootWidget) then
            Visit(w.WidgetTree.RootWidget, depth + 1)
        end
    end
    Visit(rootWidget, 0)
    return list
end

local function DiscoverWidgetProps(w)
    local okCls, cls = pcall(function() return w:GetClass() end)
    if not okCls or not Core.IsValidObj(cls) then return nil end

    local clsAddr = cls:GetAddress()
    local cached = ClassPropCache[clsAddr]
    if cached then return cached end

    local info = { MachProps = {}, RecProps = {}, ObjPropNames = {} }
    local seen = {}
    local cur = cls
    for _ = 1, 5 do
        if not Core.IsValidObj(cur) then break end
        pcall(function()
            cur:ForEachProperty(function(prop)
                local pname = prop:GetFName():ToString()
                if not seen[pname] then
                    seen[pname] = true
                    local pcls = prop.GetClass and prop:GetClass():GetFName():ToString() or ""
                    if pcls:find("ObjectProperty", 1, true) then
                        info.ObjPropNames[#info.ObjPropNames + 1] = pname
                    end
                end
            end)
        end)
        if cur:GetFName():ToString() == "UserWidget" then break end
        local okSup, sup = pcall(function() return cur:GetSuperStruct() end)
        cur = okSup and sup or nil
    end

    local asmCls = Core.FindOrLoadClass(PATHS.AssemblerObjClass)
    local recCls = Core.FindOrLoadClass(PATHS.RecipeClass)
    local diagParts = {}
    for _, pname in ipairs(info.ObjPropNames) do
        local okV, val = pcall(function() return w[pname] end)
        if okV and Core.IsValidObj(val) then
            local vCls = SafeClassName(val)
            diagParts[#diagParts + 1] = pname .. ":" .. vCls
            local isAsm = (Core.IsValidObj(asmCls) and pcall(function() return val:IsA(asmCls) end) and val:IsA(asmCls))
                or vCls:find("Assembler", 1, true) ~= nil
            local isRec = (Core.IsValidObj(recCls) and pcall(function() return val:IsA(recCls) end) and val:IsA(recCls))
                or vCls:find("Recipe", 1, true) ~= nil
            if isAsm then
                info.MachProps[#info.MachProps + 1] = pname
            elseif isRec then
                info.RecProps[#info.RecProps + 1] = pname
            end
        end
    end

    -- Standard fallback candidate names in case object wasn't assigned until Construct+1
    for _, pname in ipairs({ "AssemblerObject", "Assembler", "MachineObject", "Machine", "SimulationObject", "TargetObject", "TargetMachine" }) do
        info.MachProps[#info.MachProps + 1] = pname
    end
    for _, pname in ipairs({ "Recipe", "CurrentRecipe", "SelectedRecipe" }) do
        info.RecProps[#info.RecProps + 1] = pname
    end

    ClassPropCache[clsAddr] = info
    local clsName = SafeName(cls)
    if not LoggedDiag["props:" .. clsName] then
        LoggedDiag["props:" .. clsName] = true
        Core.Log(string.format("[AssemblerInputRates] Class %s objProps=[%s]", clsName, table.concat(diagParts, ", ")))
    end
    return info
end

local function ResolveAssemblerAndRecipe(w, st)
    local pInfo = DiscoverWidgetProps(w)
    local mach, rec = nil, nil

    if pInfo then
        for _, pname in ipairs(pInfo.MachProps) do
            local okV, v = pcall(function() return w[pname] end)
            if okV and Core.IsValidObj(v) then
                local hasRec, r = pcall(function() return v.Recipe end)
                if hasRec then
                    mach = v
                    if Core.IsValidObj(r) then rec = r end
                    break
                end
            end
        end
        if not Core.IsValidObj(rec) then
            for _, pname in ipairs(pInfo.RecProps) do
                local okV, v = pcall(function() return w[pname] end)
                if okV and Core.IsValidObj(v) then
                    local okIn = pcall(function() return v.Inputs end)
                    if okIn then
                        rec = v
                        break
                    end
                end
            end
        end
        if not Core.IsValidObj(mach) and not Core.IsValidObj(rec) then
            for _, pname in ipairs(pInfo.ObjPropNames) do
                local okV, v = pcall(function() return w[pname] end)
                if okV and Core.IsValidObj(v) then
                    local hasRec, r = pcall(function() return v.Recipe end)
                    if hasRec and r ~= nil then
                        mach = v
                        if Core.IsValidObj(r) then rec = r end
                        break
                    end
                    local okIn, inVal = pcall(function() return v.Inputs end)
                    if okIn and inVal ~= nil and v.GetCraftingSeconds then
                        rec = v
                        break
                    end
                end
            end
        end
    end

    -- Fallback: match displayed crafting output item against active world assemblers
    if not Core.IsValidObj(rec) and Core.IsValidObj(st.RefOutputItemWidget) then
        local shownItem = nil
        pcall(function() shownItem = st.RefOutputItemWidget.Item end)
        if Core.IsValidObj(shownItem) and Core.IsValidObj(shownItem.Recipe) then
            rec = shownItem.Recipe
        end
    end

    return mach, rec
end

local function FindHeaderPanelAndRefs(w)
    local treeRoot = Core.IsValidObj(w.WidgetTree) and w.WidgetTree.RootWidget or w
    local all = WalkWidgetTree(treeRoot)

    local rateTextW, nameTextW, craftingLabelW, itemWidgetW = nil, nil, nil, nil
    local textDiag = {}
    for _, node in ipairs(all) do
        local cls = SafeClassName(node)
        local txt = ReadWidgetText(node)
        if txt then
            textDiag[#textDiag + 1] = string.format("%s(%s)='%s'", SafeName(node), cls, txt)
            if not rateTextW and txt:match("/%s*min") then
                rateTextW = node
            elseif not craftingLabelW and txt:lower():match("^%s*crafting%s*$") then
                craftingLabelW = node
            end
        end
        if not itemWidgetW and cls:find("WBP_Item", 1, true) then
            itemWidgetW = node
        end
    end

    if not LoggedDiag["tree:" .. SafeClassName(w)] then
        LoggedDiag["tree:" .. SafeClassName(w)] = true
        Core.Log(string.format("[AssemblerInputRates] %s widgets=%d texts=[%s]",
            SafeClassName(w), #all, table.concat(textDiag, "; ")))
    end

    local anchor = rateTextW or craftingLabelW
    if not Core.IsValidObj(anchor) then
        return nil
    end

    -- Find the product name sibling inside the VerticalBox holding rateTextW
    if Core.IsValidObj(rateTextW) then
        local rateParent = nil
        pcall(function() rateParent = rateTextW:GetParent() end)
        if Core.IsValidObj(rateParent) and rateParent.GetChildrenCount then
            local cnt = rateParent:GetChildrenCount()
            for i = 0, cnt - 1 do
                local ch = rateParent:GetChildAt(i)
                if Core.IsValidObj(ch) and ch:GetAddress() ~= rateTextW:GetAddress() then
                    local t = ReadWidgetText(ch)
                    if t then
                        nameTextW = ch
                        break
                    end
                end
            end
        end
    end

    -- Walk upward from anchor to locate the enclosing HorizontalBox and Overlay/Border card
    local hBoxCls = Core.FindOrLoadClass(PATHS.HorizontalBoxClass)
    local overlayCls = Core.FindOrLoadClass(PATHS.OverlayClass)
    local borderCls = Core.FindOrLoadClass(PATHS.BorderClass)
    local headerHBox = nil
    local cardOverlay = nil

    local cur = anchor
    for _ = 1, 7 do
        if not Core.IsValidObj(cur) then break end
        if not headerHBox and Core.IsValidObj(hBoxCls) and cur:IsA(hBoxCls) then
            -- Verify this HorizontalBox is wider than just a single label wrapper
            local okCnt, cnt = pcall(function() return cur:GetChildrenCount() end)
            if okCnt and cnt >= 2 then
                headerHBox = cur
            end
        end
        if headerHBox and Core.IsValidObj(overlayCls) and cur:IsA(overlayCls) then
            cardOverlay = cur
            break
        end
        if headerHBox and Core.IsValidObj(borderCls) and cur:IsA(borderCls) then
            -- Check if the Border sits inside a wrapping Overlay
            local bParent = nil
            pcall(function() bParent = cur:GetParent() end)
            if Core.IsValidObj(bParent) and Core.IsValidObj(overlayCls) and bParent:IsA(overlayCls) then
                cardOverlay = bParent
            end
            break
        end
        local okP, p = pcall(function() return cur:GetParent() end)
        cur = okP and p or nil
    end

    return {
        RateText = rateTextW,
        NameText = nameTextW,
        CraftingText = craftingLabelW,
        RefOutputItemWidget = itemWidgetW,
        HeaderHBox = headerHBox,
        CardOverlay = cardOverlay,
    }
end

local function CreateRightSideContainer(w, refs)
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return nil end

    local outer = Core.GetWidgetOuter(w)
    local rootPanel = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local vWrap = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local labelTxt = Core.CreateUserWidget(PATHS.WBPTextClass, w, pc)
    local itemsBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    if not (Core.IsValidObj(rootPanel) and Core.IsValidObj(vWrap) and Core.IsValidObj(labelTxt) and Core.IsValidObj(itemsBox)) then
        return nil
    end

    pcall(function()
        rootPanel:SetMaxDesiredWidth(185.0)
        rootPanel:SetMaxDesiredHeight(68.0)
        if rootPanel.SetClipping then
            rootPanel:SetClipping(1) -- EWidgetClipping::ClipToBounds
        end
    end)
    rootPanel:AddChild(vWrap)

    local lblSz = math.min(GetRefFontSize(refs.CraftingText, 10), 10)
    CopyTextStyle(labelTxt, refs.CraftingText or refs.RateText, lblSz, COLORS.LabelMuted)
    pcall(function() labelTxt:SetText(Core.MakeText("Requires")) end)

    local lblSlot = vWrap:AddChildToVerticalBox(labelTxt)
    if Core.IsValidObj(lblSlot) then
        pcall(function()
            lblSlot:SetHorizontalAlignment(1) -- HAlign_Left
            lblSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 2.0 })
        end)
    end

    local itemsSlot = vWrap:AddChildToVerticalBox(itemsBox)
    if Core.IsValidObj(itemsSlot) then
        pcall(function()
            itemsSlot:SetVerticalAlignment(2)
            itemsSlot:SetHorizontalAlignment(1)
        end)
    end

    local attached = false
    if Core.IsValidObj(refs.CardOverlay) then
        local oSlot = refs.CardOverlay:AddChildToOverlay(rootPanel)
        if Core.IsValidObj(oSlot) then
            pcall(function()
                oSlot:SetHorizontalAlignment(3) -- HAlign_Right
                oSlot:SetVerticalAlignment(2)   -- VAlign_Center
                oSlot:SetPadding({ Left = 8.0, Top = 4.0, Right = 22.0, Bottom = 4.0 })
            end)
            attached = true
        end
    elseif Core.IsValidObj(refs.HeaderHBox) then
        pcall(function()
            if Core.IsValidObj(refs.HeaderHBox.Slot) and refs.HeaderHBox.Slot.SetHorizontalAlignment then
                refs.HeaderHBox.Slot:SetHorizontalAlignment(0) -- HAlign_Fill
            end
        end)

        local spacer = Core.CreateRawWidget(PATHS.SpacerClass, outer)
        if Core.IsValidObj(spacer) then
            local spSlot = refs.HeaderHBox:AddChildToHorizontalBox(spacer)
            if Core.IsValidObj(spSlot) then
                pcall(function()
                    spSlot:SetSize({ SizeRule = 1, Value = 1.0 })
                end)
            end
        end

        local rSlot = refs.HeaderHBox:AddChildToHorizontalBox(rootPanel)
        if Core.IsValidObj(rSlot) then
            pcall(function()
                rSlot:SetVerticalAlignment(2)   -- VAlign_Center
                rSlot:SetHorizontalAlignment(3) -- HAlign_Right
                rSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 8.0, Bottom = 0.0 })
            end)
            attached = true
        end
    end

    if not attached then
        return nil
    end

    CopyTextStyle(labelTxt, refs.CraftingText or refs.RateText, lblSz, COLORS.LabelMuted)
    return {
        RootPanel = rootPanel,
        LabelTxt = labelTxt,
        ItemsBox = itemsBox,
    }
end

local function RebuildInputRateEntries(st, inputs)
    if not Core.IsValidObj(st.ItemsBox) or not Core.IsValidObj(st.RootPanel) then return end

    pcall(function() st.ItemsBox:ClearChildren() end)

    if #inputs == 0 then
        pcall(function() st.RootPanel:SetVisibility(1) end) -- Collapsed
        return
    end
    pcall(function() st.RootPanel:SetVisibility(0) end) -- Visible

    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end
    local outer = Core.GetWidgetOuter(st.Widget)

    local isSingle = (#inputs == 1)
    local iconPx = isSingle and 26.0 or ((#inputs == 2) and 18.0 or 15.0)
    local padPx = isSingle and 3.0 or 2.0

    for _, inp in ipairs(inputs) do
        local rowBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
        local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, st.Widget, pc)
        if Core.IsValidObj(rowBox) and Core.IsValidObj(itemW) then
            pcall(function()
                itemW:SetIconSize(iconPx)
                itemW:SetItem(inp.Item)
            end)

            local iconBorder = Core.CreateRawWidget(PATHS.BorderClass, outer)
            if Core.IsValidObj(iconBorder) then
                pcall(function()
                    iconBorder:SetBrushColor(COLORS.SlotBg)
                    iconBorder:SetPadding({ Left = padPx, Top = padPx, Right = padPx, Bottom = padPx })
                    iconBorder:AddChild(itemW)
                end)
                local iSlot = rowBox:AddChildToHorizontalBox(iconBorder)
                if Core.IsValidObj(iSlot) then
                    pcall(function()
                        iSlot:SetVerticalAlignment(2)
                        iSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 6.0, Bottom = 0.0 })
                    end)
                end
            else
                local iSlot = rowBox:AddChildToHorizontalBox(itemW)
                if Core.IsValidObj(iSlot) then
                    pcall(function()
                        iSlot:SetVerticalAlignment(2)
                        iSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 6.0, Bottom = 0.0 })
                    end)
                end
            end

            if isSingle then
                local vBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
                local nameTxt = Core.CreateUserWidget(PATHS.WBPTextClass, st.Widget, pc)
                local rateTxt = Core.CreateUserWidget(PATHS.WBPTextClass, st.Widget, pc)
                if Core.IsValidObj(vBox) and Core.IsValidObj(nameTxt) and Core.IsValidObj(rateTxt) then
                    CopyTextStyle(nameTxt, st.Refs.NameText or st.Refs.RateText, 11, COLORS.WhiteText)
                    CopyTextStyle(rateTxt, st.Refs.RateText, 11, COLORS.RateTint)
                    pcall(function()
                        nameTxt:SetText(Core.MakeText(GetItemDisplayName(inp.Item)))
                        rateTxt:SetText(Core.MakeText(FormatRate(inp.Rate)))
                    end)
                    local s1 = vBox:AddChildToVerticalBox(nameTxt)
                    if Core.IsValidObj(s1) then
                        pcall(function() s1:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 1.0 }) end)
                    end
                    vBox:AddChildToVerticalBox(rateTxt)
                    local vSlot = rowBox:AddChildToHorizontalBox(vBox)
                    if Core.IsValidObj(vSlot) then
                        pcall(function() vSlot:SetVerticalAlignment(2) end)
                    end
                    CopyTextStyle(nameTxt, st.Refs.NameText or st.Refs.RateText, 11, COLORS.WhiteText)
                    CopyTextStyle(rateTxt, st.Refs.RateText, 11, COLORS.RateTint)
                end
            else
                local lineTxt = Core.CreateUserWidget(PATHS.WBPTextClass, st.Widget, pc)
                if Core.IsValidObj(lineTxt) then
                    local fontSz = (#inputs == 2) and 10 or 9
                    CopyTextStyle(lineTxt, st.Refs.RateText, fontSz, COLORS.WhiteText)
                    pcall(function()
                        lineTxt:SetText(Core.MakeText(string.format("%s  %s", FormatRate(inp.Rate), GetItemDisplayName(inp.Item))))
                    end)
                    local tSlot = rowBox:AddChildToHorizontalBox(lineTxt)
                    if Core.IsValidObj(tSlot) then
                        pcall(function() tSlot:SetVerticalAlignment(2) end)
                    end
                    CopyTextStyle(lineTxt, st.Refs.RateText, fontSz, COLORS.WhiteText)
                end
            end

            local rowSlot = st.ItemsBox:AddChildToVerticalBox(rowBox)
            if Core.IsValidObj(rowSlot) then
                pcall(function()
                    rowSlot:SetPadding({ Left = 0.0, Top = 1.0, Right = 0.0, Bottom = 1.0 })
                end)
            end
        end
    end
end

RefreshAssemblerWidget = function(st)
    if not st or not Core.IsValidObj(st.Widget) then return false end

    local mach, rec = ResolveAssemblerAndRecipe(st.Widget, st)
    if not Core.IsValidObj(rec) then
        if st.LastSig ~= "none" then
            st.LastSig = "none"
            RebuildInputRateEntries(st, {})
        end
        return true
    end

    local craftSec = 1.0
    pcall(function()
        local sec = rec:GetCraftingSeconds()
        if type(sec) == "number" and sec > 0.0001 then
            craftSec = sec
        end
    end)

    local bonusMult = 1.0
    if Core.IsValidObj(mach) then
        pcall(function()
            local bm = Core.GetFPFloat(mach.BonusMultiplier)
            if bm > 0.0001 then bonusMult = bm end
        end)
    end

    local outAmt = 1.0
    pcall(function()
        local outStack = rec.Output
        if outStack and Core.IsValidObj(outStack.Item) then
            outAmt = tonumber(outStack.Amount) or 1.0
        else
            local outs = rec:GetOutputs()
            if outs then
                StationData.ForEachArray(outs, function(_, elem)
                    if outAmt == 1.0 then
                        local s = Core.UnwrapStruct(elem)
                        if s and Core.IsValidObj(s.Item) then
                            outAmt = tonumber(s.Amount) or 1.0
                        end
                    end
                end)
            end
        end
    end)
    if outAmt <= 0.0 then outAmt = 1.0 end

    local displayedOutRate = nil
    local rawRateText = ReadWidgetText(st.Refs.RateText)
    if rawRateText then
        local numStr = rawRateText:match("([%d%.]+)%s*/%s*min")
        if numStr then
            local parsed = tonumber(numStr)
            if parsed and parsed > 0.0 then
                displayedOutRate = parsed
            end
        end
    end

    local recAddr = rec:GetAddress()
    local sig = string.format("%s:%.3f:%.3f", tostring(recAddr), tonumber(displayedOutRate) or -1.0, bonusMult)
    if sig == st.LastSig then
        return true
    end
    st.LastSig = sig

    local inputs = {}
    local okIn, inArr = pcall(function() return rec.Inputs end)
    if okIn and inArr then
        StationData.ForEachArray(inArr, function(_, elem)
            local stIn = Core.UnwrapStruct(elem)
            if stIn and Core.IsValidObj(stIn.Item) then
                local inAmt = tonumber(stIn.Amount) or 1.0
                local rate = displayedOutRate and (displayedOutRate * (inAmt / outAmt)) or ((inAmt * 60.0 / craftSec) * bonusMult)
                inputs[#inputs + 1] = {
                    Item = stIn.Item,
                    Amount = inAmt,
                    Rate = rate,
                }
            end
        end)
    end

    RebuildInputRateEntries(st, inputs)
    return true
end

local function EnsurePollLoop()
    if PollActive then return end
    PollActive = true
    local function Tick()
        local anyActive = false
        for addr, st in pairs(InjectedAssemblers) do
            if st and Core.IsValidObj(st.Widget) then
                anyActive = true
                pcall(RefreshAssemblerWidget, st)
            else
                InjectedAssemblers[addr] = nil
            end
        end
        if anyActive then
            ExecuteInGameThreadWithDelay(180, Tick)
        else
            PollActive = false
        end
    end
    ExecuteInGameThreadWithDelay(180, Tick)
end

local function OnAssemblerConstructed(w)
    if not Core.IsValidObj(w) then return end
    local addr = w:GetAddress()
    if InjectedAssemblers[addr] and Core.IsValidObj(InjectedAssemblers[addr].RootPanel) then
        RefreshAssemblerWidget(InjectedAssemblers[addr])
        return
    end

    local refs = FindHeaderPanelAndRefs(w)
    if not refs then
        Core.Log("[AssemblerInputRates] Could not find header panel refs on " .. SafeClassName(w))
        return
    end

    local ui = CreateRightSideContainer(w, refs)
    if not ui then
        Core.Log("[AssemblerInputRates] Failed to attach right-side input container on " .. SafeClassName(w))
        return
    end

    local st = {
        Widget = w,
        Refs = refs,
        RootPanel = ui.RootPanel,
        LabelTxt = ui.LabelTxt,
        ItemsBox = ui.ItemsBox,
        LastSig = nil,
    }
    InjectedAssemblers[addr] = st
    RefreshAssemblerWidget(st)
    EnsurePollLoop()
end

Feature.WatchWidgets = {
    WBP_Assembler_C     = OnAssemblerConstructed,
    WBP_ShipAssembler_C = OnAssemblerConstructed,
}

function Feature.Init()
    Core.Log("[AssemblerInputRates] Initialized.")
end

function Feature.OnClientRestart()
    InjectedAssemblers = {}
end

return Feature
