-- Eqol Feature: Designer Power Generation & Consumption Stats
-- Displays total Power Generation and Power Consumption alongside Mass/Hull/Dimensions
-- in Ship Designer and Station Designer, matching the exact native column styling.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "DesignerPowerStats",
}

local PATHS = {
    WBPTextClass     = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    VerticalBoxClass = "/Script/UMG.VerticalBox",
    BorderClass      = "/Script/UMG.Border",
    SizeBoxClass     = "/Script/UMG.SizeBox",
}

local COLORS = {
    GoldAccent = { R = 0.94, G = 0.65, B = 0.05, A = 1.0 },
    WhiteValue = { R = 0.95, G = 0.96, B = 0.98, A = 1.0 },
    RedValue   = { R = 1.00, G = 0.35, B = 0.35, A = 1.0 },
    GreenValue = { R = 0.30, G = 0.90, B = 0.40, A = 1.0 },
}

local InjectedDesigners = {} -- hudAddr -> { GenText, ConsText }

local function FormatPower(kw)
    local val = tonumber(kw) or 0.0
    if math.abs(val) >= 1000.0 then
        return string.format("%.1f MW", val / 1000.0)
    end
    return string.format("%.0f kW", val)
end

local function ComputePowerFromObject(obj)
    local gen, cons = 0.0, 0.0
    if not Core.IsValidObj(obj) then return gen, cons end

    local okHasFn, hasFn = pcall(function() return obj.GetDisplayMaxPower ~= nil end)
    if okHasFn and hasFn then
        local okMax, maxP = pcall(function() return obj:GetDisplayMaxPower() end)
        local okCur, curP = pcall(function() return obj:GetDisplayPower() end)
        local val = (okMax and type(maxP) == "number" and maxP ~= 0) and maxP or ((okCur and type(curP) == "number") and curP or 0)
        if val > 0 then
            gen = gen + val
        elseif val < 0 then
            cons = cons + math.abs(val)
        end
        if val ~= 0 then return gen, cons end
    end

    for _, prop in ipairs({ "PowerGeneration", "PowerProduction", "MaxPowerProduction", "GeneratedPower" }) do
        local ok, v = pcall(function() return obj[prop] end)
        if ok and v ~= nil then
            local num = (type(v) == "number") and v or Core.GetFPFloat(v)
            if num > 0 then
                gen = gen + num
                break
            end
        end
    end

    for _, prop in ipairs({ "PowerConsumption", "MaxPowerConsumption", "RequiredPower", "ConsumedPower" }) do
        local ok, v = pcall(function() return obj[prop] end)
        if ok and v ~= nil then
            local num = (type(v) == "number") and v or Core.GetFPFloat(v)
            if num > 0 then
                cons = cons + num
                break
            end
        end
    end

    return gen, cons
end

local function ResolveDesignerObject(designerHud)
    if not Core.IsValidObj(designerHud) then return nil end

    -- WBP_DesignerHUD_C stores ["Designer Pawn"] -> BPC_Designer -> Designer
    local designer = nil
    pcall(function()
        local pawn = designerHud["Designer Pawn"]
        if Core.IsValidObj(pawn) and Core.IsValidObj(pawn.BPC_Designer) then
            designer = pawn.BPC_Designer.Designer
        end
    end)
    if Core.IsValidObj(designer) then return designer end

    pcall(function() designer = designerHud.Designer end)
    if Core.IsValidObj(designer) then return designer end

    local pc = Core.GetLocalPlayerController()
    if Core.IsValidObj(pc) and Core.IsValidObj(pc.Pawn) then
        pcall(function()
            if Core.IsValidObj(pc.Pawn.BPC_Designer) then
                designer = pc.Pawn.BPC_Designer.Designer
            end
        end)
    end
    return designer
end

local function CollectObjectsFromArray(arr, seen, out)
    if not arr or type(arr.GetArrayNum) ~= "function" then return end
    StationData.ForEachArray(arr, function(_, elem)
        local obj = Core.UnwrapArrayElem(elem)
        if Core.IsValidObj(obj) then
            local a = obj:GetAddress()
            if not seen[a] then
                seen[a] = true
                out[#out + 1] = obj
            end
        end
    end)
end

local LoggedDesignerInfo = false
local HookedBlueprintStats = false
local RefreshDesignerPowerStats -- forward declaration

local function EnsureBlueprintStatsHook(designer, hud)
    if HookedBlueprintStats or not Core.IsValidObj(designer) then return end
    local dCls = designer:GetClass()
    if not Core.IsValidObj(dCls) then return end
    local full = dCls:GetFullName()
    local clsPath = full and full:match("^%S+ (.+)$") or nil
    if not clsPath then return end
    if Core.TryRegisterHook("Designer_RefreshBlueprintStats", clsPath .. ":RefreshBlueprintStats", function()
        ExecuteInGameThreadWithDelay(50, function()
            for _, st in pairs(InjectedDesigners) do
                if Core.IsValidObj(st.Hud) then
                    RefreshDesignerPowerStats(st.Hud)
                end
            end
        end)
    end) then
        HookedBlueprintStats = true
    end
end

local function ComputeDesignerPower(designerHud)
    local designer = ResolveDesignerObject(designerHud)
    if not Core.IsValidObj(designer) then return 0.0, 0.0 end

    EnsureBlueprintStatsHook(designer, designerHud)

    local frame = nil
    pcall(function() frame = designer:GetFrame() end)

    local isStationFrame = false
    if Core.IsValidObj(frame) then
        pcall(function()
            local clsName = frame:GetClass():GetFName():ToString()
            if clsName and string.find(clsName, "Station", 1, true) then
                isStationFrame = true
            end
        end)
    end

    local pgGen, pgCons = 0.0, 0.0
    if isStationFrame and frame.GetPowerGrid then
        local okPG, pg = pcall(function() return frame:GetPowerGrid() end)
        if okPG and Core.IsValidObj(pg) then
            pgGen = Core.GetFPFloat(pg.MaxProduction)
            pgCons = Core.GetFPFloat(pg.MaxConsumption)
        end
    end

    local costGen, costCons = 0.0, 0.0
    local okCost, costArr = pcall(function() return designer.FrameBlueprintCost end)
    if okCost and costArr then
        local costCount = 0
        StationData.ForEachArray(costArr, function(_, elem)
            costCount = costCount + 1
            local itemObj = nil
            local amt = 1
            pcall(function() itemObj = elem.Item end)
            pcall(function()
                if type(elem.Amount) == "number" then amt = elem.Amount end
            end)
            if Core.IsValidObj(itemObj) and amt > 0 then
                if not LoggedDesignerInfo then
                    LoggedDesignerInfo = true
                    pcall(function()
                        local iCls = itemObj:GetClass()
                        Core.Log("DesignerPowerStats: CostItem=" .. itemObj:GetFName():ToString() .. " class=" .. iCls:GetFName():ToString())
                        if iCls.ForEachProperty then
                            iCls:ForEachProperty(function(prop)
                                local n = prop:GetFName():ToString()
                                if string.find(n, "Block", 1, true) or string.find(n, "Power", 1, true)
                                    or string.find(n, "Actor", 1, true) or string.find(n, "Class", 1, true)
                                    or string.find(n, "Machine", 1, true) or string.find(n, "Building", 1, true) then
                                    Core.Log("DesignerPowerStats [Item prop]: " .. n .. " (" .. prop:GetClass():GetFName():ToString() .. ")")
                                end
                            end)
                        end
                    end)
                end
                local g, c = ComputePowerFromObject(itemObj)
                costGen = costGen + g * amt
                costCons = costCons + c * amt
            end
        end)
        if not LoggedDesignerInfo then
            Core.Log("DesignerPowerStats: FrameBlueprintCost count=" .. tostring(costCount))
        end
    end

    return math.max(pgGen, costGen), math.max(pgCons, costCons)
end

local function CopyTextStyle(dstText, srcText, fallbackSize, overrideColor)
    if not Core.IsValidObj(dstText) then return end
    pcall(function()
        local sz = nil
        if Core.IsValidObj(srcText) and srcText.Size ~= nil then
            local n = tonumber(srcText.Size)
            if n and n >= 8 then sz = n end
        end
        if not sz and Core.IsValidObj(srcText) and Core.IsValidObj(srcText.TextBlock) and srcText.TextBlock.Font then
            local n = tonumber(srcText.TextBlock.Font.Size)
            if n and n >= 8 then sz = n end
        end
        if dstText.SetSize then dstText:SetSize(sz or fallbackSize or 15) end

        local just = nil
        if Core.IsValidObj(srcText) and srcText.Justification ~= nil then
            just = srcText.Justification
        end
        if dstText.SetJustification then dstText:SetJustification(just or 1) end

        if overrideColor and Core.IsValidObj(dstText.TextBlock) then
            dstText.TextBlock:SetColorAndOpacity({ SpecifiedColor = overrideColor, ColorUseRule = 0 })
        end
    end)
end

local function CreateDesignerStatColumn(hud, pc, outer, statsHBox, refColVBox, refLabelText, refValueText, labelStr, gridColIdx, labelColor, labelSize)
    local colVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local lblTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)
    local divBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local divLine = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local valTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)

    if not (Core.IsValidObj(colVBox) and Core.IsValidObj(lblTxt) and Core.IsValidObj(divBox)
        and Core.IsValidObj(divLine) and Core.IsValidObj(valTxt)) then
        return nil, nil
    end

    local accentCol = labelColor or COLORS.GoldAccent
    CopyTextStyle(lblTxt, refLabelText, labelSize or 15, accentCol)
    CopyTextStyle(valTxt, refValueText, 18, COLORS.WhiteValue)

    pcall(function()
        lblTxt:SetText(Core.MakeText(labelStr))
        valTxt:SetText(Core.MakeText("0 kW / 0 kW"))
        divBox:SetHeightOverride(1.75)
        divLine:SetBrushColor(accentCol)
    end)
    divBox:AddChild(divLine)

    local s1 = colVBox:AddChildToVerticalBox(lblTxt)
    if Core.IsValidObj(s1) then
        pcall(function()
            s1:SetHorizontalAlignment(2) -- HAlign_Center
            s1:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 1.5 })
        end)
    end
    local s2 = colVBox:AddChildToVerticalBox(divBox)
    if Core.IsValidObj(s2) then
        pcall(function()
            s2:SetHorizontalAlignment(0) -- HAlign_Fill
            s2:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 3.0 })
        end)
    end
    local s3 = colVBox:AddChildToVerticalBox(valTxt)
    if Core.IsValidObj(s3) then
        pcall(function() s3:SetHorizontalAlignment(2) end) -- HAlign_Center
    end

    local hBoxCls = Core.FindOrLoadClass("/Script/UMG.HorizontalBox")
    local gridCls = Core.FindOrLoadClass("/Script/UMG.GridPanel")

    if Core.IsValidObj(hBoxCls) and statsHBox:IsA(hBoxCls) then
        local okH, hSlot = pcall(function() return statsHBox:AddChildToHorizontalBox(colVBox) end)
        if okH and Core.IsValidObj(hSlot) then
            pcall(function()
                hSlot:SetVerticalAlignment(2) -- VAlign_Center
                if Core.IsValidObj(refColVBox) and Core.IsValidObj(refColVBox.Slot) then
                    hSlot:SetPadding(refColVBox.Slot.Padding)
                else
                    hSlot:SetPadding({ Left = 24.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end
            end)
        end
    elseif Core.IsValidObj(gridCls) and statsHBox:IsA(gridCls) then
        local colIdx = gridColIdx or 3
        local okG, gSlot = pcall(function() return statsHBox:AddChildToGrid(colVBox, 0, colIdx) end)
        if okG and Core.IsValidObj(gSlot) then
            pcall(function()
                gSlot:SetVerticalAlignment(2)
                gSlot:SetHorizontalAlignment(2)
                local pad = { Left = 22.0, Top = 0.0, Right = 22.0, Bottom = 0.0 }
                if Core.IsValidObj(refColVBox) and Core.IsValidObj(refColVBox.Slot) then
                    local rp = refColVBox.Slot.Padding
                    if rp and ((tonumber(rp.Left) or 0) >= 16 or (tonumber(rp.Right) or 0) >= 16) then
                        pad = rp
                    end
                end
                gSlot:SetPadding(pad)
            end)
        end
    else
        pcall(function() statsHBox:AddChild(colVBox) end)
    end

    -- Re-apply colors/sizes after parenting because WBP_Text_C Construct() resets TextBlock defaults
    CopyTextStyle(lblTxt, refLabelText, labelSize or 15, accentCol)
    CopyTextStyle(valTxt, refValueText, 18, COLORS.WhiteValue)

    return valTxt, lblTxt
end

local function FindStatsContainerPanel(hud)
    local hullText = hud.HullText
    local hullColVBox = Core.IsValidObj(hullText) and hullText:GetParent() or nil
    local hBoxCls = Core.FindOrLoadClass("/Script/UMG.HorizontalBox")
    local gridCls = Core.FindOrLoadClass("/Script/UMG.GridPanel")

    -- Walk up from HullText to find the HorizontalBox or GridPanel holding the stat columns
    local cur = hullColVBox
    for _ = 1, 4 do
        if not Core.IsValidObj(cur) then break end
        local parent = nil
        pcall(function() parent = cur:GetParent() end)
        if Core.IsValidObj(parent) then
            if (Core.IsValidObj(hBoxCls) and parent:IsA(hBoxCls)) or (Core.IsValidObj(gridCls) and parent:IsA(gridCls)) then
                return parent, cur, hullText, hullColVBox
            end
        end
        cur = parent
    end

    -- Fallback: drill down from StatsContainer
    if Core.IsValidObj(hud.StatsContainer) then
        local okC, ch = pcall(function() return hud.StatsContainer:GetChildAt(0) end)
        if okC and Core.IsValidObj(ch) then
            return ch, hullColVBox, hullText, hullColVBox
        end
    end
    return nil, nil, nil, nil
end

local LoggedHudInit = {}

RefreshDesignerPowerStats = function(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    local st = InjectedDesigners[addr]

    if not LoggedHudInit[addr] then
        LoggedHudInit[addr] = true
        Core.Log("DesignerPowerStats: RefreshDesignerPowerStats start")
    end

    if not st or not Core.IsValidObj(st.PowerText) then
        local statsPanel, refCol, hullText, hullColVBox = FindStatsContainerPanel(hud)
        if not Core.IsValidObj(statsPanel) then return end

        local refLabelText = nil
        local labelColor = COLORS.GoldAccent
        local labelSize = 15
        if Core.IsValidObj(hullColVBox) then
            pcall(function()
                local cnt = hullColVBox:GetChildrenCount()
                local hullAddr = Core.IsValidObj(hullText) and hullText:GetAddress() or 0
                for i = 0, cnt - 1 do
                    local ch = hullColVBox:GetChildAt(i)
                    if Core.IsValidObj(ch) and ch:GetAddress() ~= hullAddr and Core.IsValidObj(ch.TextBlock) then
                        refLabelText = ch
                        local okS, s = pcall(function() return tonumber(ch.Size) end)
                        if okS and s and s >= 8 then
                            labelSize = s
                        else
                            local okFS, fs = pcall(function() return tonumber(ch.TextBlock.Font.Size) end)
                            if okFS and fs and fs >= 8 then labelSize = fs end
                        end
                        pcall(function()
                            local c = ch.TextBlock.ColorAndOpacity.SpecifiedColor
                            if c and c.A and c.A > 0.1 then
                                labelColor = { R = c.R, G = c.G, B = c.B, A = c.A }
                            end
                        end)
                        break
                    end
                end
            end)
        end

        local outer = Core.GetWidgetOuter(hud)
        local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
        local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

        local nextCol = 3
        pcall(function()
            local maxCol = -1
            local count = statsPanel:GetChildrenCount()
            for i = 0, count - 1 do
                local child = statsPanel:GetChildAt(i)
                if Core.IsValidObj(child) and Core.IsValidObj(child.Slot) and child.Slot.Column ~= nil then
                    local c = tonumber(child.Slot.Column)
                    if c and c > maxCol then maxCol = c end
                end
            end
            if maxCol >= 0 then
                nextCol = maxCol + 1
            elseif count > 0 then
                nextCol = count
            end
        end)

        local pwrTxt, pwrLbl = CreateDesignerStatColumn(hud, pc, outer, statsPanel, refCol, refLabelText, hullText, "Power", nextCol, labelColor, labelSize)
        if not Core.IsValidObj(pwrTxt) then return end

        st = { Hud = hud, PowerText = pwrTxt, PowerLabel = pwrLbl, LabelColor = labelColor }
        InjectedDesigners[addr] = st
        Core.Log("DesignerPowerStats: column injected, computing power")
    end

    local gen, cons = ComputeDesignerPower(hud)
    pcall(function()
        st.PowerText:SetText(Core.MakeText(string.format("%s / %s", FormatPower(cons), FormatPower(gen))))
        local lblCol = st.LabelColor or COLORS.GoldAccent
        if Core.IsValidObj(st.PowerLabel) and Core.IsValidObj(st.PowerLabel.TextBlock) then
            st.PowerLabel.TextBlock:SetColorAndOpacity({ SpecifiedColor = lblCol, ColorUseRule = 0 })
        end
        local valColor = (cons > gen and cons > 0) and COLORS.RedValue or COLORS.WhiteValue
        if Core.IsValidObj(st.PowerText.TextBlock) then
            st.PowerText.TextBlock:SetColorAndOpacity({ SpecifiedColor = valColor, ColorUseRule = 0 })
        end
    end)
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_DesignerHUD_C = function(hud)
        ExecuteInGameThreadWithDelay(150, function()
            if Core.IsValidObj(hud) then
                RefreshDesignerPowerStats(hud)
            end
        end)
    end,
}

function Feature.RegisterHooks()
    for _, fnName in ipairs({ "Refresh", "RefreshStats" }) do
        Core.TryRegisterHook(
            "DesignerHUD_" .. fnName,
            "/Game/Blueprints/Widgets/HUDs/WBP_DesignerHUD.WBP_DesignerHUD_C:" .. fnName,
            function(Context)
                local hud = Context:get()
                if Core.IsValidObj(hud) then
                    ExecuteInGameThreadWithDelay(50, function()
                        if Core.IsValidObj(hud) then
                            RefreshDesignerPowerStats(hud)
                        end
                    end)
                end
            end
        )
    end
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedDesigners) do
        if not Core.IsValidObj(st.PowerText) then
            InjectedDesigners[addr] = nil
        end
    end
end

return Feature
