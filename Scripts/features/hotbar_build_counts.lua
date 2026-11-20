-- Eqol Feature: Hotbar Craftable Count Labels
-- Step 1: Attach a visible hard-coded "1" badge onto each WBP_HotbarSlot_C to confirm
-- rendering & positioning before wiring live buildable cost counts.

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
    ContentWidgetCls = "/Script/UMG.ContentWidget",
}

local COLOR_OK = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local BG_BADGE = { R = 0.02, G = 0.03, B = 0.05, A = 0.78 }

local TrackedHuds = {}
local DiagLogged = false

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

local function AttachHardcodedBadgeToSlot(slotWidget, pc, logChain)
    if not Core.IsValidObj(slotWidget) then return nil, nil, "invalid" end

    local overlayCls = Core.FindOrLoadClass(PATHS.OverlayClass)
    local canvasCls = Core.FindOrLoadClass(PATHS.CanvasPanelClass)
    local contentCls = Core.FindOrLoadClass(PATHS.ContentWidgetCls)

    local outerParent = nil
    pcall(function() outerParent = slotWidget:GetParent() end)
    local outerParentAddr = Core.IsValidObj(outerParent) and outerParent:GetAddress() or nil

    -- Inspect Image_60 (the icon inside WBP_HotbarSlot_C) and its parent chain
    local img = nil
    pcall(function() img = slotWidget.Image_60 end)

    local chainNames = {}
    local targetOverlay = nil
    local targetCanvas = nil
    local imgDirectParent = nil

    if Core.IsValidObj(img) and img.GetParent then
        local cur = img
        for step = 1, 5 do
            local okP, p = pcall(function() return cur:GetParent() end)
            if not okP or not Core.IsValidObj(p) then break end
            if outerParentAddr and p:GetAddress() == outerParentAddr then break end
            local pCls = "?"
            pcall(function() pCls = p:GetClass():GetFName():ToString() end)
            chainNames[#chainNames + 1] = pCls
            if step == 1 then imgDirectParent = p end
            if not targetOverlay and Core.IsValidObj(overlayCls) and p:IsA(overlayCls) then
                targetOverlay = p
            elseif not targetCanvas and Core.IsValidObj(canvasCls) and p:IsA(canvasCls) then
                targetCanvas = p
            end
            cur = p
        end
    end

    if logChain then
        Core.Log(string.format("[HotbarCounts] Slot1 Image_60=%s parentChain=[%s]",
            tostring(Core.IsValidObj(img)), table.concat(chainNames, " -> ")))
    end

    local outer = Core.GetWidgetOuter(slotWidget)
    local badge = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local label = Core.CreateUserWidget(PATHS.WBPTextClass, slotWidget, pc)
    if not (Core.IsValidObj(badge) and Core.IsValidObj(label)) then
        return nil, nil, "create_failed"
    end

    local function ApplyHardcodedText()
        pcall(function()
            badge:SetBrushColor(BG_BADGE)
            badge:SetPadding({ Left = 4.0, Top = 1.0, Right = 4.0, Bottom = 1.0 })
            badge:SetVisibility(3) -- HitTestInvisible (visible!)
            label:SetSize(11)
            label:SetText(Core.MakeText("1"))
            label:SetVisibility(3)
            if Core.IsValidObj(label.TextBlock) then
                label.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLOR_OK, ColorUseRule = 0 })
                label.TextBlock:SetVisibility(3)
            end
        end)
    end

    pcall(function() badge:AddChild(label) end)
    ApplyHardcodedText()
    -- Re-apply 1 frame later in case WBP_Text_C:Construct overrides text/size
    ExecuteInGameThreadAfterFrames(1, function()
        if Core.IsValidObj(badge) and Core.IsValidObj(label) then
            ApplyHardcodedText()
        end
    end)

    -- 1. Prefer attaching directly to an Overlay inside the slot
    if Core.IsValidObj(targetOverlay) then
        local oSlot = targetOverlay:AddChildToOverlay(badge)
        if Core.IsValidObj(oSlot) then
            pcall(function()
                oSlot:SetHorizontalAlignment(3) -- Right
                oSlot:SetVerticalAlignment(3)   -- Bottom
                oSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 3.0, Bottom = 2.0 })
            end)
        end
        return badge, label, "Overlay"
    end

    -- 2. Or a CanvasPanel inside the slot
    if Core.IsValidObj(targetCanvas) then
        local cSlot = targetCanvas:AddChildToCanvas(badge)
        if Core.IsValidObj(cSlot) then
            pcall(function()
                cSlot:SetAnchors({ Minimum = { X = 1.0, Y = 1.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                cSlot:SetAlignment({ X = 1.0, Y = 1.0 })
                cSlot:SetAutoSize(true)
                cSlot:SetPosition({ X = -3.0, Y = -2.0 })
            end)
        end
        return badge, label, "Canvas"
    end

    -- 3. If Image_60 sits directly inside a single-child ContentWidget (Border / SizeBox),
    --    wrap Image_60 + badge together inside a new Overlay so the badge overlays the icon cleanly!
    if Core.IsValidObj(img) and Core.IsValidObj(imgDirectParent)
        and Core.IsValidObj(contentCls) and imgDirectParent:IsA(contentCls)
    then
        local wrapOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
        if Core.IsValidObj(wrapOverlay) then
            pcall(function()
                img:RemoveFromParent()
                local iSlot = wrapOverlay:AddChildToOverlay(img)
                if Core.IsValidObj(iSlot) then
                    iSlot:SetHorizontalAlignment(0) -- Fill
                    iSlot:SetVerticalAlignment(0)   -- Fill
                end
                local bSlot = wrapOverlay:AddChildToOverlay(badge)
                if Core.IsValidObj(bSlot) then
                    bSlot:SetHorizontalAlignment(3) -- Right
                    bSlot:SetVerticalAlignment(3)   -- Bottom
                    bSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 3.0, Bottom = 2.0 })
                end
                imgDirectParent:SetContent(wrapOverlay)
            end)
            return badge, label, "WrappedOverlay"
        end
    end

    return nil, nil, "no_host"
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
        local bestPanelChildren = nil
        local directUserWidgets = {}

        for _, entry in ipairs(props) do
            local val = entry.val
            if Core.IsValidObj(val) then
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
            end
        end

        if bestPanelChildren then
            for _, cw in ipairs(bestPanelChildren) do addSlot(cw) end
        elseif #directUserWidgets >= 4 then
            for _, cw in ipairs(directUserWidgets) do addSlot(cw) end
        end
    end

    return hotbarWidget, slots
end

local function EnsureHudHotbarTracked(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    if TrackedHuds[addr] and Core.IsValidObj(TrackedHuds[addr].Hud) then
        return
    end

    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local hotbarWidget, rawSlots = DiscoverHotbarSlots(hud)
    if #rawSlots == 0 then return end

    local attachedCount = 0
    local firstMode = "?"
    for i, slotW in ipairs(rawSlots) do
        local badge, label, mode = AttachHardcodedBadgeToSlot(slotW, pc, (i == 1 and not DiagLogged))
        if i == 1 then firstMode = mode end
        if Core.IsValidObj(badge) and Core.IsValidObj(label) then
            attachedCount = attachedCount + 1
        end
    end

    DiagLogged = true
    TrackedHuds[addr] = { Hud = hud }
    Core.Log(string.format("[HotbarCounts] Step1 hardcoded '1': attached %d/%d slots (mode=%s)",
        attachedCount, #rawSlots, tostring(firstMode)))
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
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        ExecuteInGameThreadWithDelay(250, function()
            if Core.IsValidObj(hud) then
                EnsureHudHotbarTracked(hud)
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
