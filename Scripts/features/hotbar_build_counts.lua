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

    if buildable.GetBuildCost then
        local ok, arr = pcall(function() return buildable:GetBuildCost() end)
        if ok and arr then
            collectFromArr(arr)
            if #stacks > 0 then return stacks end
        end
    end

    for _, prop in ipairs({ "BuildCost", "Cost", "Costs", "Ingredients", "RequiredItems" }) do
        local ok, arr = pcall(function() return buildable[prop] end)
        if ok and arr then
            collectFromArr(arr)
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

local function GetHotbarBuildablesArray(pc, hud, hotbarWidget)
    local list = {}
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
                local found = {}
                local idx = 0
                StationData.ForEachArray(arr, function(i, elem)
                    idx = idx + 1
                    local u = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(u) then
                        found[i] = u
                    else
                        local st = Core.UnwrapStruct(elem)
                        if st then
                            for _, fName in ipairs({ "Buildable", "Item", "Object" }) do
                                local okF, v = pcall(function() return st[fName] end)
                                if okF and Core.IsValidObj(v) then
                                    found[i] = v
                                    break
                                end
                            end
                        end
                    end
                end)
                if idx > 0 then
                    return found
                end
            end
        end
    end
    return list
end

local function ExtractSlotBuildable(slotWidget, slotIndex, hotbarArr)
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
    end

    if hotbarArr and slotIndex and Core.IsValidObj(hotbarArr[slotIndex]) then
        return hotbarArr[slotIndex]
    end
    return nil
end

local function FindAttachHostInSlot(slotWidget)
    if not Core.IsValidObj(slotWidget) then return nil, nil end

    local overlayCls = Core.FindOrLoadClass(PATHS.OverlayClass)
    local canvasCls = Core.FindOrLoadClass(PATHS.CanvasPanelClass)

    -- Prefer an Overlay or CanvasPanel inside the slot's WidgetTree so the label overlays the icon cleanly
    local wt = nil
    pcall(function() wt = slotWidget.WidgetTree end)
    if Core.IsValidObj(wt) then
        local root = nil
        pcall(function() root = wt.RootWidget end)
        if Core.IsValidObj(root) then
            if Core.IsValidObj(overlayCls) and root:IsA(overlayCls) then
                return root, "Overlay"
            elseif Core.IsValidObj(canvasCls) and root:IsA(canvasCls) then
                return root, "Canvas"
            end
        end
        if wt.AllWidgets then
            local bestOverlay, bestCanvas = nil, nil
            StationData.ForEachArray(wt.AllWidgets, function(_, elem)
                local w = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(w) then
                    if not bestOverlay and Core.IsValidObj(overlayCls) and w:IsA(overlayCls) then
                        bestOverlay = w
                    elseif not bestCanvas and Core.IsValidObj(canvasCls) and w:IsA(canvasCls) then
                        bestCanvas = w
                    end
                end
            end)
            if Core.IsValidObj(bestOverlay) then return bestOverlay, "Overlay" end
            if Core.IsValidObj(bestCanvas) then return bestCanvas, "Canvas" end
        end
    end

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

    -- Fallback: scan HUD WidgetTree.AllWidgets once for any widget whose class or name contains "Hotbar"
    local hudWT = nil
    pcall(function() hudWT = hud.WidgetTree end)
    if not Core.IsValidObj(hotbarWidget) and Core.IsValidObj(hudWT) and hudWT.AllWidgets then
        StationData.ForEachArray(hudWT.AllWidgets, function(_, elem)
            if Core.IsValidObj(hotbarWidget) then return end
            local w = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(w) then
                local okN, cn = pcall(function() return w:GetClass():GetFName():ToString():lower() end)
                if okN and cn and cn:find("hotbar", 1, true) and not cn:find("slot", 1, true) then
                    hotbarWidget = w
                end
            end
        end)
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

    -- 1. Check direct slot arrays or container children on hotbarWidget
    if Core.IsValidObj(hotbarWidget) then
        for _, prop in ipairs({ "Slots", "HotbarSlots", "SlotWidgets", "Buttons" }) do
            local ok, arr = pcall(function() return hotbarWidget[prop] end)
            if ok and arr then
                StationData.ForEachArray(arr, function(_, elem)
                    addSlot(Core.UnwrapArrayElem(elem))
                end)
            end
        end

        -- Check HorizontalBox / UniformGridPanel / Container children inside hotbarWidget
        if #slots == 0 then
            for _, prop in ipairs({ "Container", "SlotsContainer", "SlotContainer", "HotbarContainer", "HorizontalBox", "HorizontalBox_0", "Grid" }) do
                local ok, box = pcall(function() return hotbarWidget[prop] end)
                if ok and Core.IsValidObj(box) and box.GetAllChildren then
                    local okCh, ch = pcall(function() return box:GetAllChildren() end)
                    if okCh and ch then
                        StationData.ForEachArray(ch, function(_, elem)
                            addSlot(Core.UnwrapArrayElem(elem))
                        end)
                    end
                end
                if #slots > 0 then break end
            end
        end

        -- Walk hotbarWidget.WidgetTree.AllWidgets for slot widgets
        if #slots == 0 then
            local hbWT = nil
            pcall(function() hbWT = hotbarWidget.WidgetTree end)
            if Core.IsValidObj(hbWT) and hbWT.AllWidgets then
                StationData.ForEachArray(hbWT.AllWidgets, function(_, elem)
                    local w = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(w) then
                        local okN, cn = pcall(function() return w:GetClass():GetFName():ToString():lower() end)
                        if okN and cn and (cn:find("hotbar", 1, true) or cn:find("slot", 1, true)) and cn:find("wbp_", 1, true) then
                            addSlot(w)
                        end
                    end
                end)
            end
        end
    end

    -- 2. Fallback: look for WBP_*Hotbar*Slot* directly in hud.WidgetTree.AllWidgets
    if #slots == 0 and Core.IsValidObj(hudWT) and hudWT.AllWidgets then
        StationData.ForEachArray(hudWT.AllWidgets, function(_, elem)
            local w = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(w) then
                local okN, cn = pcall(function() return w:GetClass():GetFName():ToString():lower() end)
                if okN and cn and cn:find("hotbar", 1, true) and cn:find("slot", 1, true) then
                    addSlot(w)
                end
            end
        end)
    end

    return hotbarWidget, slots
end

local function EnsureHudHotbarTracked(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    if TrackedHuds[addr] and Core.IsValidObj(TrackedHuds[addr].Hud) and #TrackedHuds[addr].Slots > 0 then
        return
    end

    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local hotbarWidget, rawSlots = DiscoverHotbarSlots(hud)
    if #rawSlots == 0 then
        if not DiagLogged then
            DiagLogged = true
            local hbName = Core.IsValidObj(hotbarWidget) and hotbarWidget:GetClass():GetFName():ToString() or "nil"
            Core.Log(string.format("[HotbarCounts] No slots found yet on WBP_CharacterHUD_C (hotbar=%s)", hbName))
        end
        return
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
        TrackedHuds[addr] = {
            Hud = hud,
            HotbarWidget = hotbarWidget,
            Slots = trackedSlots,
        }
        if not DiagLogged then
            DiagLogged = true
            local hbName = Core.IsValidObj(hotbarWidget) and hotbarWidget:GetClass():GetFName():ToString() or "nil"
            local sName = rawSlots[1]:GetClass():GetFName():ToString()
            Core.Log(string.format("[HotbarCounts] Attached %d/%d slot labels (hotbar=%s, slotCls=%s)",
                #trackedSlots, #rawSlots, hbName, sName))
        end
    end
end

local function RefreshHotbarCounts()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end

    local inv = GetPlayerInventory(pc)
    local invCounts, hasCountsMap = BuildPlayerInventoryCounts(inv)
    local anyValid = false

    for addr, entry in pairs(TrackedHuds) do
        if not Core.IsValidObj(entry.Hud) then
            TrackedHuds[addr] = nil
        else
            anyValid = true
            local hudVisible = false
            pcall(function()
                hudVisible = (entry.Hud:IsInViewport() == true) and (entry.Hud:IsVisible() == true)
            end)
            if hudVisible then
                local hotbarArr = GetHotbarBuildablesArray(pc, entry.Hud, entry.HotbarWidget)
                for _, s in ipairs(entry.Slots) do
                    if Core.IsValidObj(s.SlotWidget) and Core.IsValidObj(s.Badge) and Core.IsValidObj(s.Label) then
                        local bld = ExtractSlotBuildable(s.SlotWidget, s.Index, hotbarArr)
                        local count = Core.IsValidObj(bld) and ComputeCraftableCount(bld, inv, invCounts, hasCountsMap) or nil
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
    for _ in pairs(TrackedHuds) do
        StartPoll()
        break
    end
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
    DiagLogged = false
end

return Feature
