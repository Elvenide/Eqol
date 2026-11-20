-- Eqol Feature: Hotbar Craftable Count Labels
-- Displays a numeric label on each bottom-hotbar buildable slot showing how many of
-- that machine can be built with the resources currently in the player's inventory.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "HotbarBuildCounts",
}

local PATHS = {
    WBPTextClass     = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    OverlayClass     = "/Script/UMG.Overlay",
    CanvasPanelClass = "/Script/UMG.CanvasPanel",
    BorderClass      = "/Script/UMG.Border",
    PanelWidgetClass = "/Script/UMG.PanelWidget",
    BuildableClass   = "/Script/MainSequence.Buildable",
}

local COLOR_OK = { R = 1.0, G = 1.0, B = 1.0, A = 0.98 }
local COLOR_ZERO = { R = 0.96, G = 0.36, B = 0.32, A = 0.98 }
local BG_BADGE = { R = 0.02, G = 0.03, B = 0.05, A = 0.68 }

local TrackedHuds = {} -- hudAddr -> { Hud, HotbarWidget, Slots = { { SlotWidget, Index, Badge, Label, LastText, LastZero, LastVis } } }
local PollActive = false
local DiagLogged = false

local function GetItemKey(item)
    if not Core.IsValidObj(item) then return nil end
    local ok, n = pcall(function() return item:GetFName():ToString() end)
    if ok and type(n) == "string" and n ~= "" then
        return n
    end
    return tostring(item:GetAddress())
end

local function FormatCount(n)
    if n >= 10000 then
        return string.format("%.0fk", n / 1000.0)
    elseif n >= 1000 then
        return string.format("%.1fk", n / 1000.0)
    end
    return tostring(math.floor(n))
end

local function GetPlayerInventory(pc)
    if not Core.IsValidObj(pc) then return nil end
    local playerObj = pc.PlayerObject
    if Core.IsValidObj(playerObj) then
        if playerObj.GetInventory then
            local ok, inv = pcall(function() return playerObj:GetInventory() end)
            if ok and Core.IsValidObj(inv) then return inv end
        end
        for _, prop in ipairs({ "Inventory", "PlayerInventory", "CharacterInventory" }) do
            local ok, inv = pcall(function() return playerObj[prop] end)
            if ok and Core.IsValidObj(inv) then return inv end
        end
    end
    if pc.GetInventory then
        local ok, inv = pcall(function() return pc:GetInventory() end)
        if ok and Core.IsValidObj(inv) then return inv end
    end
    return nil
end

local function BuildPlayerInventoryCounts(inv)
    local counts = {}
    if not Core.IsValidObj(inv) then return counts, false end
    local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
    if not okSlots or not slots then
        return counts, false
    end
    StationData.ForEachArray(slots, function(_, elem)
        local st = Core.UnwrapStruct(elem)
        if st and Core.IsValidObj(st.Item) then
            local amt = tonumber(st.Amount) or 0
            if amt > 0 then
                local k = GetItemKey(st.Item)
                if k then
                    counts[k] = (counts[k] or 0) + amt
                end
            end
        end
    end)
    return counts, true
end

local function GetBuildableCostStacks(buildable)
    if not Core.IsValidObj(buildable) then return nil end
    local stacks = {}

    local function collectFromArr(arr)
        if not arr then return end
        StationData.ForEachArray(arr, function(_, elem)
            local st = Core.UnwrapStruct(elem)
            if st and Core.IsValidObj(st.Item) then
                local amt = tonumber(st.Amount) or 0
                if amt > 0 then
                    stacks[#stacks + 1] = { Item = st.Item, Amount = amt }
                end
            end
        end)
    end

    local function collectFromCostObj(val)
        if not val then return end
        collectFromArr(val)
        if #stacks > 0 then return end
        local st = Core.UnwrapStruct(val)
        if st then
            for _, subProp in ipairs({ "Items", "ItemStacks", "RequiredItems", "ItemsRequired", "Costs", "Ingredients" }) do
                local okS, subArr = pcall(function() return st[subProp] end)
                if okS and subArr then
                    collectFromArr(subArr)
                    if #stacks > 0 then return end
                end
            end
        end
    end

    for _, fnName in ipairs({ "GetBuildCost", "CostAsBuildingCost", "GetCost" }) do
        if buildable[fnName] then
            local ok, res = pcall(function() return buildable[fnName](buildable) end)
            if ok and res then
                collectFromCostObj(res)
                if #stacks > 0 then return stacks end
            end
        end
    end

    for _, prop in ipairs({ "BuildCost", "ItemsRequired", "Cost", "Costs", "BuildingCost", "Ingredients", "RequiredItems" }) do
        local ok, val = pcall(function() return buildable[prop] end)
        if ok and val then
            collectFromCostObj(val)
            if #stacks > 0 then return stacks end
        end
    end

    local okRec, rec = pcall(function() return buildable.Recipe end)
    if okRec and Core.IsValidObj(rec) then
        local okIn, inArr = pcall(function() return rec.Inputs end)
        if okIn and inArr then
            collectFromArr(inArr)
        end
    end

    return (#stacks > 0) and stacks or nil
end

local function ComputeCraftableCount(buildable, inv, invCounts, hasCountsMap)
    local stacks = GetBuildableCostStacks(buildable)
    if not stacks or #stacks == 0 then return nil end

    -- Aggregate duplicate ingredient items if any
    local neededByKey = {}
    local itemByKey = {}
    for _, st in ipairs(stacks) do
        local k = GetItemKey(st.Item)
        if k then
            neededByKey[k] = (neededByKey[k] or 0) + st.Amount
            itemByKey[k] = st.Item
        end
    end

    local minCount = math.huge
    for k, reqAmt in pairs(neededByKey) do
        if reqAmt > 0 then
            local have = 0
            if hasCountsMap then
                have = invCounts[k] or 0
            elseif Core.IsValidObj(inv) and inv.GetItemAmount then
                local okA, a = pcall(function() return inv:GetItemAmount(itemByKey[k]) end)
                if okA and type(a) == "number" then have = a end
            end
            local c = math.floor(have / reqAmt)
            if c < minCount then minCount = c end
            if minCount == 0 then break end
        end
    end

    if minCount == math.huge then return nil end
    return minCount
end

local function KeyToString(k)
    if k == nil then return nil end
    if type(k) == "string" then return k end
    if type(k) == "number" then return tostring(k) end
    local unwrapped = k
    local okG, g = pcall(function() return k.get and k:get() or k end)
    if okG and g ~= nil then unwrapped = g end
    if type(unwrapped) == "string" then return unwrapped end
    if type(unwrapped) == "number" then return tostring(unwrapped) end
    local okS, s = pcall(function()
        if unwrapped.ToString then return unwrapped:ToString() end
        return tostring(unwrapped)
    end)
    if okS and type(s) == "string" and s ~= "" then return s end
    return nil
end

local function GetHotbarBuildablesData(pc, hud, hotbarWidget)
    local result = { byName = {}, byIndex = {}, count = 0 }
    local sources = {}
    if Core.IsValidObj(hotbarWidget) then sources[#sources + 1] = hotbarWidget end
    if Core.IsValidObj(hud) then sources[#sources + 1] = hud end
    if Core.IsValidObj(pc) then
        if Core.IsValidObj(pc.PlayerObject) then sources[#sources + 1] = pc.PlayerObject end
        sources[#sources + 1] = pc
    end

    for _, src in ipairs(sources) do
        for _, prop in ipairs({ "HotbarBuildables", "Hotbar", "HotbarItems", "Buildables" }) do
            local ok, arr = pcall(function() return src[prop] end)
            if ok and arr then
                local foundCount = 0
                StationData.ForEachArray(arr, function(rawKey, elem)
                    local u = Core.UnwrapArrayElem(elem)
                    if not Core.IsValidObj(u) then
                        local st = Core.UnwrapStruct(elem)
                        if st then
                            for _, fName in ipairs({ "Buildable", "Item", "Object" }) do
                                local okF, v = pcall(function() return st[fName] end)
                                if okF and Core.IsValidObj(v) then
                                    u = v
                                    break
                                end
                            end
                        end
                    end
                    if Core.IsValidObj(u) then
                        foundCount = foundCount + 1
                        local kUnwrapped = rawKey
                        local okG, g = pcall(function() return rawKey and rawKey.get and rawKey:get() or rawKey end)
                        if okG and g ~= nil then kUnwrapped = g end

                        if type(kUnwrapped) == "number" then
                            result.byIndex[kUnwrapped] = u
                            result.byIndex[kUnwrapped + 1] = result.byIndex[kUnwrapped + 1] or u
                            result.byName[tostring(kUnwrapped)] = u
                        else
                            local ks = KeyToString(kUnwrapped)
                            if ks and ks ~= "" then
                                result.byName[ks] = u
                                result.byName[ks:lower()] = u
                                local num = tonumber(ks:match("(%d+)$"))
                                if num then
                                    -- Hotbar0 is slot 10, Hotbar1..9 are slots 1..9
                                    local idx1 = (num == 0) and 10 or num
                                    result.byIndex[idx1] = u
                                end
                            end
                        end
                    end
                end)
                if foundCount > 0 then
                    result.count = foundCount
                    return result
                end
            end
        end
    end
    return result
end

local function CollectReflectedObjectProps(uobj)
    local out = {}
    if not Core.IsValidObj(uobj) then return out end
    local seen = {}
    pcall(function()
        local cls = uobj:GetClass()
        while Core.IsValidObj(cls) do
            local cName = cls:GetFName():ToString()
            if cName == "UserWidget" or cName == "Widget" or cName == "Object" then break end
            cls:ForEachProperty(function(prop)
                local pName = prop:GetFName():ToString()
                if not seen[pName] then
                    seen[pName] = true
                    local okV, val = pcall(function() return uobj[pName] end)
                    if okV and val ~= nil then
                        out[#out + 1] = { name = pName, val = val }
                    end
                end
            end)
            cls = cls:GetSuperStruct()
        end
    end)
    return out
end

local function ExtractSlotBuildable(slotWidget, slotIndex, hotbarData)
    if Core.IsValidObj(slotWidget) then
        for _, prop in ipairs({
            "Buildable", "CurrentBuildable", "BoundBuildable", "AssignedBuildable",
            "HotbarBuildable", "SelectedBuildable", "BuildObject",
        }) do
            local ok, v = pcall(function() return slotWidget[prop] end)
            if ok and Core.IsValidObj(v) then
                return v
            end
        end
        if slotWidget.GetBuildable then
            local ok, v = pcall(function() return slotWidget:GetBuildable() end)
            if ok and Core.IsValidObj(v) then
                return v
            end
        end

        -- Match WBP_HotbarSlot_C's "Mapping Name" against HotbarBuildables TMap keys
        if hotbarData and hotbarData.byName then
            local okM, mapVal = pcall(function() return slotWidget["Mapping Name"] end)
            if okM and mapVal ~= nil then
                local ms = KeyToString(mapVal)
                if ms and ms ~= "" then
                    local hit = hotbarData.byName[ms] or hotbarData.byName[ms:lower()]
                    if Core.IsValidObj(hit) then return hit end
                    local num = tonumber(ms:match("(%d+)$"))
                    if num then
                        local idx1 = (num == 0) and 10 or num
                        if Core.IsValidObj(hotbarData.byIndex[idx1]) then
                            return hotbarData.byIndex[idx1]
                        end
                    end
                end
            end
        end
    end

    if hotbarData and hotbarData.byIndex and slotIndex and Core.IsValidObj(hotbarData.byIndex[slotIndex]) then
        return hotbarData.byIndex[slotIndex]
    end
    return nil
end

local function FindAttachHostInSlot(slotWidget)
    if not Core.IsValidObj(slotWidget) then return nil, nil end

    local overlayCls = Core.FindOrLoadClass(PATHS.OverlayClass)
    local canvasCls = Core.FindOrLoadClass(PATHS.CanvasPanelClass)
    local panelCls = Core.FindOrLoadClass(PATHS.PanelWidgetClass)
    local widgetCls = Core.FindOrLoadClass("/Script/UMG.Widget")

    local outerParent = nil
    pcall(function() outerParent = slotWidget:GetParent() end)
    local outerParentAddr = Core.IsValidObj(outerParent) and outerParent:GetAddress() or nil

    local bestOverlay, bestCanvas, bestPanel = nil, nil, nil
    local function consider(w)
        if not Core.IsValidObj(w) then return end
        if outerParentAddr and w:GetAddress() == outerParentAddr then return end
        if not bestOverlay and Core.IsValidObj(overlayCls) and w:IsA(overlayCls) then
            bestOverlay = w
        elseif not bestCanvas and Core.IsValidObj(canvasCls) and w:IsA(canvasCls) then
            bestCanvas = w
        elseif not bestPanel and Core.IsValidObj(panelCls) and w:IsA(panelCls) then
            bestPanel = w
        end
    end

    local props = CollectReflectedObjectProps(slotWidget)
    for _, entry in ipairs(props) do
        local w = entry.val
        if Core.IsValidObj(w) then
            consider(w)
            -- Walk GetParent() on child widgets inside WBP_HotbarSlot_C to reach its
            -- internal root Overlay / CanvasPanel even when the root wasn't marked IsVariable.
            if Core.IsValidObj(widgetCls) and w:IsA(widgetCls) and w.GetParent then
                local cur = w
                for _ = 1, 4 do
                    local okP, p = pcall(function() return cur:GetParent() end)
                    if not okP or not Core.IsValidObj(p) then break end
                    if outerParentAddr and p:GetAddress() == outerParentAddr then break end
                    consider(p)
                    cur = p
                end
            end
        end
    end

    if Core.IsValidObj(bestOverlay) then return bestOverlay, "Overlay" end
    if Core.IsValidObj(bestCanvas) then return bestCanvas, "Canvas" end
    if Core.IsValidObj(bestPanel) then return bestPanel, "Panel" end
    return nil, nil
end

local function AttachCountBadgeToSlot(slotWidget, hud, pc)
    local host, hostKind = FindAttachHostInSlot(slotWidget)
    if not Core.IsValidObj(host) then return nil, nil end

    local outer = Core.GetWidgetOuter(slotWidget)
    local badge = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local label = Core.CreateUserWidget(PATHS.WBPTextClass, slotWidget, pc)
    if not (Core.IsValidObj(badge) and Core.IsValidObj(label)) then
        return nil, nil
    end

    pcall(function()
        badge:SetBrushColor(BG_BADGE)
        badge:SetPadding({ Left = 3.0, Top = 0.0, Right = 3.0, Bottom = 0.0 })
        badge:SetVisibility(1) -- Collapsed until a buildable is bound
        label:SetSize(10)
        label:SetText(Core.MakeText(""))
        label:SetVisibility(3) -- HitTestInvisible
        if Core.IsValidObj(label.TextBlock) then
            label.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLOR_OK, ColorUseRule = 0 })
        end
        badge:AddChild(label)
    end)

    if hostKind == "Overlay" then
        local oSlot = host:AddChildToOverlay(badge)
        if Core.IsValidObj(oSlot) then
            pcall(function()
                oSlot:SetHorizontalAlignment(3) -- Right
                oSlot:SetVerticalAlignment(3)   -- Bottom
                oSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 3.0, Bottom = 2.0 })
            end)
        end
    elseif hostKind == "Canvas" then
        local cSlot = host:AddChildToCanvas(badge)
        if Core.IsValidObj(cSlot) then
            pcall(function()
                cSlot:SetAnchors({ Minimum = { X = 1.0, Y = 1.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                cSlot:SetAlignment({ X = 1.0, Y = 1.0 })
                cSlot:SetAutoSize(true)
                cSlot:SetPosition({ X = -3.0, Y = -2.0 })
            end)
        end
    elseif hostKind == "Panel" then
        pcall(function() host:AddChild(badge) end)
    end

    return badge, label
end

local function DiscoverHotbarSlots(hud)
    if not Core.IsValidObj(hud) then return nil, {} end

    local hotbarWidget = nil
    for _, prop in ipairs({
        "WBP_Hotbar", "Hotbar", "BuildHotbar", "WBP_BuildHotbar",
        "HotbarWidget", "QuickBar", "WBP_QuickBar",
    }) do
        local ok, w = pcall(function() return hud[prop] end)
        if ok and Core.IsValidObj(w) then
            hotbarWidget = w
            break
        end
    end

    -- Fallback: reflect properties on WBP_CharacterHUD_C for any Hotbar widget
    if not Core.IsValidObj(hotbarWidget) then
        for _, entry in ipairs(CollectReflectedObjectProps(hud)) do
            local w = entry.val
            if Core.IsValidObj(w) then
                local okN, cn = pcall(function() return w:GetClass():GetFName():ToString():lower() end)
                if okN and cn and cn:find("hotbar", 1, true) then
                    hotbarWidget = w
                    break
                end
            end
        end
    end

    local slots = {}
    local seen = {}
    local function addSlot(w)
        if not Core.IsValidObj(w) then return end
        local a = w:GetAddress()
        if seen[a] then return end
        seen[a] = true
        slots[#slots + 1] = w
    end

    local userWidgetCls = Core.FindOrLoadClass("/Script/UMG.UserWidget")
    local panelCls = Core.FindOrLoadClass(PATHS.PanelWidgetClass)

    if Core.IsValidObj(hotbarWidget) then
        local props = CollectReflectedObjectProps(hotbarWidget)
        local propSummary = {}
        local bestPanelChildren = nil
        local directUserWidgets = {}

        for _, entry in ipairs(props) do
            local val = entry.val
            if Core.IsValidObj(val) then
                local cn = "?"
                pcall(function() cn = val:GetClass():GetFName():ToString() end)
                if #propSummary < 16 then
                    propSummary[#propSummary + 1] = entry.name .. ":" .. cn
                end
                if Core.IsValidObj(panelCls) and val:IsA(panelCls) and val.GetAllChildren then
                    local okCh, ch = pcall(function() return val:GetAllChildren() end)
                    if okCh and ch then
                        local uwList = {}
                        StationData.ForEachArray(ch, function(_, ce)
                            local cw = Core.UnwrapArrayElem(ce)
                            if Core.IsValidObj(cw) and Core.IsValidObj(userWidgetCls) and cw:IsA(userWidgetCls) then
                                uwList[#uwList + 1] = cw
                            end
                        end)
                        if #uwList >= 4 and #uwList <= 16 and (not bestPanelChildren or #uwList > #bestPanelChildren) then
                            bestPanelChildren = uwList
                        end
                    end
                elseif Core.IsValidObj(userWidgetCls) and val:IsA(userWidgetCls) then
                    directUserWidgets[#directUserWidgets + 1] = val
                end
            elseif type(val) == "userdata" then
                local okLen, len = pcall(function() return val.GetArrayNum and val:GetArrayNum() end)
                if okLen and type(len) == "number" and len >= 4 and len <= 16 then
                    local arrList = {}
                    StationData.ForEachArray(val, function(_, elem)
                        local cw = Core.UnwrapArrayElem(elem)
                        if Core.IsValidObj(cw) and Core.IsValidObj(userWidgetCls) and cw:IsA(userWidgetCls) then
                            arrList[#arrList + 1] = cw
                        end
                    end)
                    if #arrList >= 4 and (not bestPanelChildren or #arrList > #bestPanelChildren) then
                        bestPanelChildren = arrList
                    end
                    if #propSummary < 16 then
                        propSummary[#propSummary + 1] = string.format("%s[%d](uw=%d)", entry.name, len, #arrList)
                    end
                end
            end
        end

        if bestPanelChildren then
            for _, cw in ipairs(bestPanelChildren) do addSlot(cw) end
        elseif #directUserWidgets >= 4 then
            for _, cw in ipairs(directUserWidgets) do addSlot(cw) end
        end

        if #slots == 0 and not DiagLogged then
            DiagLogged = true
            Core.Log(string.format("[HotbarCounts] WBP_Hotbar_C reflected props=[%s]", table.concat(propSummary, ", ")))
        end
    end

    return hotbarWidget, slots
end

local PendingHuds = {} -- hudAddr -> { Hud, Attempts }

local function EnsureHudHotbarTracked(hud)
    if not Core.IsValidObj(hud) then return false end
    local addr = hud:GetAddress()
    if TrackedHuds[addr] and Core.IsValidObj(TrackedHuds[addr].Hud) and #TrackedHuds[addr].Slots > 0 then
        PendingHuds[addr] = nil
        return true
    end

    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local hotbarWidget, rawSlots = DiscoverHotbarSlots(hud)
    if #rawSlots == 0 then
        local pend = PendingHuds[addr] or { Hud = hud, Attempts = 0 }
        pend.Attempts = pend.Attempts + 1
        PendingHuds[addr] = pend
        return false
    end

    local trackedSlots = {}
    for i, slotW in ipairs(rawSlots) do
        local badge, label = AttachCountBadgeToSlot(slotW, hud, pc)
        if Core.IsValidObj(badge) and Core.IsValidObj(label) then
            trackedSlots[#trackedSlots + 1] = {
                SlotWidget = slotW,
                Index = i,
                Badge = badge,
                Label = label,
                LastText = nil,
                LastZero = nil,
                LastVis = 1,
            }
        end
    end

    if #trackedSlots > 0 then
        PendingHuds[addr] = nil
        TrackedHuds[addr] = {
            Hud = hud,
            HotbarWidget = hotbarWidget,
            Slots = trackedSlots,
        }
        local hbName = Core.IsValidObj(hotbarWidget) and hotbarWidget:GetClass():GetFName():ToString() or "nil"
        local sName = rawSlots[1]:GetClass():GetFName():ToString()
        Core.Log(string.format("[HotbarCounts] Attached %d/%d slot labels (hotbar=%s, slotCls=%s)",
            #trackedSlots, #rawSlots, hbName, sName))
        return true
    else
        if not DiagLogged then
            DiagLogged = true
            local sName = rawSlots[1]:GetClass():GetFName():ToString()
            Core.Log(string.format("[HotbarCounts] Found %d slots (%s) but no Overlay/Canvas host inside slot",
                #rawSlots, sName))
        end
    end
    return false
end

local function RefreshHotbarCounts()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end

    -- Retry any HUDs whose WBP_Hotbar_C hadn't populated its slots yet on initial construct
    local anyPending = false
    for addr, pend in pairs(PendingHuds) do
        if Core.IsValidObj(pend.Hud) and pend.Attempts < 20 then
            if not EnsureHudHotbarTracked(pend.Hud) then
                anyPending = true
            end
        else
            PendingHuds[addr] = nil
        end
    end

    local inv = GetPlayerInventory(pc)
    local invCounts, hasCountsMap = BuildPlayerInventoryCounts(inv)
    local anyValid = anyPending

    for addr, entry in pairs(TrackedHuds) do
        if not Core.IsValidObj(entry.Hud) then
            TrackedHuds[addr] = nil
        else
            anyValid = true
            local hotbarData = GetHotbarBuildablesData(pc, entry.Hud, entry.HotbarWidget)
            local firstBldLogged = false
            for _, s in ipairs(entry.Slots) do
                if Core.IsValidObj(s.SlotWidget) and Core.IsValidObj(s.Badge) and Core.IsValidObj(s.Label) then
                    local bld = ExtractSlotBuildable(s.SlotWidget, s.Index, hotbarData)
                    local count = Core.IsValidObj(bld) and ComputeCraftableCount(bld, inv, invCounts, hasCountsMap) or nil
                    if not DiagLogged and not firstBldLogged and (Core.IsValidObj(bld) or s.Index == #entry.Slots) then
                        firstBldLogged = true
                        DiagLogged = true
                        local invN = 0
                        for _ in pairs(invCounts) do invN = invN + 1 end
                        local bName = Core.IsValidObj(bld) and bld:GetFName():ToString() or "nil"
                        local keys = {}
                        for k, _ in pairs(hotbarData.byName) do
                            if #keys < 6 then keys[#keys + 1] = tostring(k) end
                        end
                        local mapName = KeyToString(s.SlotWidget["Mapping Name"]) or "nil"
                        Core.Log(string.format("[HotbarCounts] RefreshDiag inv=%s(types=%d) hbCount=%d keys=[%s] slot%d(map=%s) bld=%s count=%s",
                            tostring(Core.IsValidObj(inv)), invN, hotbarData.count, table.concat(keys, ","), s.Index, mapName, bName, tostring(count)))
                    end
                    if count ~= nil then
                        local txt = FormatCount(count)
                        local isZero = (count == 0)
                        if s.LastVis ~= 3 then
                            s.LastVis = 3
                            pcall(function() s.Badge:SetVisibility(3) end) -- HitTestInvisible
                        end
                        if s.LastText ~= txt then
                            s.LastText = txt
                            pcall(function() s.Label:SetText(Core.MakeText(txt)) end)
                        end
                        if s.LastZero ~= isZero then
                            s.LastZero = isZero
                            local col = isZero and COLOR_ZERO or COLOR_OK
                            pcall(function()
                                if Core.IsValidObj(s.Label.TextBlock) then
                                    s.Label.TextBlock:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
                                end
                            end)
                        end
                    else
                        if s.LastVis ~= 1 then
                            s.LastVis = 1
                            s.LastText = nil
                            pcall(function() s.Badge:SetVisibility(1) end) -- Collapsed
                        end
                    end
                end
            end
        end
    end

    return anyValid
end

local function StartPoll()
    if PollActive then return end
    PollActive = true
    local function Tick()
        local ok, anyValid = pcall(RefreshHotbarCounts)
        if ok and anyValid then
            ExecuteInGameThreadWithDelay(500, Tick)
        else
            PollActive = false
        end
    end
    ExecuteInGameThreadWithDelay(500, Tick)
end

local function TryAttachExistingHuds()
    local okHuds, huds = pcall(FindAllOf, "WBP_CharacterHUD_C")
    if okHuds and huds then
        for _, hud in ipairs(huds) do
            if Core.IsValidObj(hud) then
                EnsureHudHotbarTracked(hud)
            end
        end
    end
    local shouldPoll = false
    for _ in pairs(TrackedHuds) do shouldPoll = true; break end
    if not shouldPoll then
        for _ in pairs(PendingHuds) do shouldPoll = true; break end
    end
    if shouldPoll then StartPoll() end
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        -- Defer slightly so hotbar children finish Construct before we scan WidgetTree
        ExecuteInGameThreadWithDelay(200, function()
            if Core.IsValidObj(hud) then
                EnsureHudHotbarTracked(hud)
                StartPoll()
            end
        end)
    end,
}

function Feature.OnClientRestart()
    ExecuteInGameThreadWithDelay(600, TryAttachExistingHuds)
end

function Feature.OnMapLoad()
    TrackedHuds = {}
    PendingHuds = {}
    DiagLogged = false
end

return Feature
