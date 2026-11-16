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

    if obj.GetDisplayMaxPower then
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

local function ComputeDesignerPower(designerHud)
    local totalGen, totalCons = 0.0, 0.0
    local designer = ResolveDesignerObject(designerHud)
    if not Core.IsValidObj(designer) then return totalGen, totalCons end

    local frame = nil
    pcall(function() frame = designer:GetFrame() end)
    if Core.IsValidObj(frame) then
        local pg = nil
        if frame.GetPowerGrid then
            pcall(function() pg = frame:GetPowerGrid() end)
        end
        if Core.IsValidObj(pg) then
            local maxP = Core.GetFPFloat(pg.MaxProduction)
            local maxC = Core.GetFPFloat(pg.MaxConsumption)
            if maxP > 0 or maxC > 0 then
                return maxP, maxC
            end
        end

        local machines = StationData.GetFrameMachines(frame)
        for _, m in ipairs(machines) do
            local g, c = ComputePowerFromObject(m)
            totalGen = totalGen + g
            totalCons = totalCons + c
        end
    end

    return totalGen, totalCons
end

local function CopyTextStyle(dstText, srcText, overrideColor)
    if not Core.IsValidObj(dstText) then return end
    pcall(function()
        if Core.IsValidObj(srcText) then
            dstText.Size = srcText.Size
            dstText.Strength = srcText.Strength
            dstText.Justification = srcText.Justification
            if dstText.SetSize then dstText:SetSize(srcText.Size) end
            if dstText.SetJustification then dstText:SetJustification(srcText.Justification) end
        else
            dstText.Size = 14
            dstText.Justification = 1 -- Center
            if dstText.SetSize then dstText:SetSize(14) end
            if dstText.SetJustification then dstText:SetJustification(1) end
        end
        if overrideColor then
            dstText.bOverrideColour = true
            dstText.Colour = overrideColor
            if dstText.SetColour then dstText:SetColour(overrideColor) end
        elseif Core.IsValidObj(srcText) then
            dstText.bOverrideColour = srcText.bOverrideColour
            dstText.Colour = srcText.Colour
            if dstText.SetColour then dstText:SetColour(srcText.Colour) end
        end
        if dstText.PreConstruct then dstText:PreConstruct(false) end
    end)
end

local function CreateDesignerStatColumn(hud, pc, outer, statsHBox, refColVBox, refLabelText, refValueText, labelStr)
    local colVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local lblTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)
    local divBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local divLine = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local valTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)

    if not (Core.IsValidObj(colVBox) and Core.IsValidObj(lblTxt) and Core.IsValidObj(divBox)
        and Core.IsValidObj(divLine) and Core.IsValidObj(valTxt)) then
        return nil
    end

    CopyTextStyle(lblTxt, refLabelText, COLORS.GoldAccent)
    CopyTextStyle(valTxt, refValueText, COLORS.WhiteValue)

    pcall(function()
        lblTxt:SetText(Core.MakeText(labelStr))
        valTxt:SetText(Core.MakeText("0 kW"))
        divBox:SetHeightOverride(2.0)
        divLine:SetBrushColor(COLORS.GoldAccent)
    end)
    divBox:AddChild(divLine)

    local s1 = colVBox:AddChildToVerticalBox(lblTxt)
    if Core.IsValidObj(s1) then
        pcall(function()
            s1:SetHorizontalAlignment(2) -- HAlign_Center
            s1:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 4.0 })
        end)
    end
    local s2 = colVBox:AddChildToVerticalBox(divBox)
    if Core.IsValidObj(s2) then
        pcall(function()
            s2:SetHorizontalAlignment(0) -- HAlign_Fill
            s2:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 4.0 })
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
        local colIdx = 3
        pcall(function()
            local ch = statsHBox:GetAllChildren()
            local cnt = 0
            StationData.ForEachArray(ch, function() cnt = cnt + 1 end)
            colIdx = cnt
        end)
        local okG, gSlot = pcall(function() return statsHBox:AddChildToGrid(colVBox, 0, colIdx) end)
        if okG and Core.IsValidObj(gSlot) then
            pcall(function()
                gSlot:SetVerticalAlignment(2)
                gSlot:SetPadding({ Left = 24.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
    else
        pcall(function() statsHBox:AddChild(colVBox) end)
    end

    return valTxt
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
                return parent, cur, hullText
            end
        end
        cur = parent
    end

    -- Fallback: drill down from StatsContainer
    if Core.IsValidObj(hud.StatsContainer) then
        local okC, ch = pcall(function() return hud.StatsContainer:GetChildAt(0) end)
        if okC and Core.IsValidObj(ch) then
            return ch, hullColVBox, hullText
        end
    end
    return nil, nil, nil
end

local function RefreshDesignerPowerStats(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    local st = InjectedDesigners[addr]

    if not st or not Core.IsValidObj(st.GenText) or not Core.IsValidObj(st.ConsText) then
        local statsPanel, refCol, hullText = FindStatsContainerPanel(hud)
        if not Core.IsValidObj(statsPanel) then return end

        local refLabelText = nil
        if Core.IsValidObj(refCol) then
            pcall(function() refLabelText = refCol:GetChildAt(0) end)
        end

        local outer = Core.GetWidgetOuter(hud)
        local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
        local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

        local genTxt = CreateDesignerStatColumn(hud, pc, outer, statsPanel, refCol, refLabelText, hullText, "Power Generation")
        local consTxt = CreateDesignerStatColumn(hud, pc, outer, statsPanel, refCol, refLabelText, hullText, "Power Consumption")
        if not (Core.IsValidObj(genTxt) and Core.IsValidObj(consTxt)) then return end

        st = { GenText = genTxt, ConsText = consTxt }
        InjectedDesigners[addr] = st
    end

    local gen, cons = ComputeDesignerPower(hud)
    pcall(function()
        st.GenText:SetText(Core.MakeText(FormatPower(gen)))
        st.ConsText:SetText(Core.MakeText(FormatPower(cons)))
        local consColor = (cons > gen and cons > 0) and COLORS.RedValue or COLORS.WhiteValue
        st.ConsText.bOverrideColour = true
        st.ConsText.Colour = consColor
        if st.ConsText.SetColour then st.ConsText:SetColour(consColor) end
        if st.ConsText.PreConstruct then st.ConsText:PreConstruct(false) end
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
                    RefreshDesignerPowerStats(hud)
                end
            end
        )
    end
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedDesigners) do
        if not Core.IsValidObj(st.GenText) then
            InjectedDesigners[addr] = nil
        end
    end
end

return Feature
