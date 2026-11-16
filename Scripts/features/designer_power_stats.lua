-- Eqol Feature: Designer Power Generation & Consumption Stats
-- Displays total Power Gen and Power Cons alongside Hull/Mass in Ship Designer and Station Designer.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "DesignerPowerStats",
}

local PATHS = {
    WBPTextClass       = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    HorizontalBoxClass = "/Script/UMG.HorizontalBox",
    VerticalBoxClass   = "/Script/UMG.VerticalBox",
}

local COLORS = {
    Green = { R = 0.05402, G = 0.7042, B = 0.05281, A = 1.0 },
    Amber = { R = 0.8917,  G = 0.6242, B = 0.0,     A = 1.0 },
    Red   = { R = 0.5177,  G = 0.0,    B = 0.04122, A = 1.0 },
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

    -- MachineObject methods / properties
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

local function ComputeDesignerPower(designerHud)
    local totalGen, totalCons = 0.0, 0.0
    if not Core.IsValidObj(designerHud) then return totalGen, totalCons end

    local designer = nil
    pcall(function() designer = designerHud.Designer end)
    if not Core.IsValidObj(designer) then
        local okAll, list = pcall(FindAllOf, "Designer")
        if okAll and list and Core.IsValidObj(list[1]) then
            designer = list[1]
        end
    end
    if not Core.IsValidObj(designer) then return totalGen, totalCons end

    -- 1. Check live preview frame machines if available
    local frame = nil
    pcall(function() frame = designer:GetFrame() end)
    if Core.IsValidObj(frame) then
        local machines = StationData.GetFrameMachines(frame)
        for _, m in ipairs(machines) do
            local g, c = ComputePowerFromObject(m)
            totalGen = totalGen + g
            totalCons = totalCons + c
        end
    end

    -- 2. Check BuildBlueprint entries/machines/blocks
    local bp = nil
    pcall(function() bp = designer:GetBlueprintForSaving() end)
    if not Core.IsValidObj(bp) then
        pcall(function() bp = designer.Blueprint end)
    end
    if Core.IsValidObj(bp) then
        for _, arrName in ipairs({ "Machines", "Blocks", "Entries" }) do
            local okArr, arr = pcall(function() return bp[arrName] end)
            if okArr and arr then
                StationData.ForEachArray(arr, function(_, elem)
                    local entry = Core.UnwrapArrayElem(elem) or elem
                    if entry then
                        local target = nil
                        pcall(function() target = entry.Buildable or entry.Block or entry.Machine end)
                        local g, c = ComputePowerFromObject(target or entry)
                        totalGen = totalGen + g
                        totalCons = totalCons + c
                    end
                end)
            end
        end
    end

    return totalGen, totalCons
end

local function FindStatsListPanel(statsContainer)
    if not Core.IsValidObj(statsContainer) then return nil end
    local okChild, child = pcall(function() return statsContainer:GetChildAt(0) end)
    if not okChild or not Core.IsValidObj(child) then return nil end

    -- Drill down one level if wrapped in a Margin/Padding/SizeBox
    if child.AddChildToVerticalBox or child.AddChildToGrid then
        return child
    end
    local okSub, sub = pcall(function() return child:GetChildAt(0) end)
    if okSub and Core.IsValidObj(sub) and (sub.AddChildToVerticalBox or sub.AddChildToGrid) then
        return sub
    end
    return child
end

local function CreateStatRow(hud, pc, outer, parentPanel, labelStr)
    local rowBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    local lblTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)
    local valTxt = Core.CreateUserWidget(PATHS.WBPTextClass, hud, pc)
    if not (Core.IsValidObj(rowBox) and Core.IsValidObj(lblTxt) and Core.IsValidObj(valTxt)) then
        return nil
    end

    pcall(function()
        lblTxt:SetSize(12)
        lblTxt:SetText(Core.MakeText(labelStr))
        valTxt:SetSize(12)
        valTxt:SetText(Core.MakeText("0 kW"))
    end)

    local s1 = rowBox:AddChildToHorizontalBox(lblTxt)
    if Core.IsValidObj(s1) then
        pcall(function()
            s1:SetSize({ Value = 1.0, SizeRule = 1 })
            s1:SetVerticalAlignment(2)
        end)
    end
    local s2 = rowBox:AddChildToHorizontalBox(valTxt)
    if Core.IsValidObj(s2) then
        pcall(function()
            s2:SetVerticalAlignment(2)
            s2:SetPadding({ Left = 12.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        end)
    end

    if parentPanel.AddChildToVerticalBox then
        local vSlot = parentPanel:AddChildToVerticalBox(rowBox)
        if Core.IsValidObj(vSlot) then
            pcall(function() vSlot:SetPadding({ Left = 0.0, Top = 4.0, Right = 0.0, Bottom = 0.0 }) end)
        end
    elseif parentPanel.AddChildToGrid then
        local rowIdx = 4
        pcall(function()
            local ch = parentPanel:GetAllChildren()
            local cnt = 0
            StationData.ForEachArray(ch, function() cnt = cnt + 1 end)
            rowIdx = cnt
        end)
        parentPanel:AddChildToGrid(rowBox, rowIdx, 0)
    else
        pcall(function() parentPanel:AddChild(rowBox) end)
    end

    return valTxt
end

local function RefreshDesignerPowerStats(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    local st = InjectedDesigners[addr]

    if not st or not Core.IsValidObj(st.GenText) or not Core.IsValidObj(st.ConsText) then
        local panel = FindStatsListPanel(hud.StatsContainer)
        if not Core.IsValidObj(panel) then return end

        local outer = Core.GetWidgetOuter(hud)
        local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
        local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

        local genTxt = CreateStatRow(hud, pc, outer, panel, "Power Gen")
        local consTxt = CreateStatRow(hud, pc, outer, panel, "Power Cons")
        if not (Core.IsValidObj(genTxt) and Core.IsValidObj(consTxt)) then return end

        st = { GenText = genTxt, ConsText = consTxt }
        InjectedDesigners[addr] = st
    end

    local gen, cons = ComputeDesignerPower(hud)
    pcall(function()
        st.GenText:SetText(Core.MakeText(FormatPower(gen)))
        st.ConsText:SetText(Core.MakeText(FormatPower(cons)))
        if st.GenText.SetColour then
            st.GenText:SetColour(COLORS.Green)
        end
        if st.ConsText.SetColour then
            st.ConsText:SetColour((cons > gen and cons > 0) and COLORS.Red or COLORS.Amber)
        end
    end)
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_DesignerHUD_C = function(hud)
        RefreshDesignerPowerStats(hud)
    end,
}

function Feature.RegisterHooks()
    for _, fnName in ipairs({ "Setup", "Refresh", "RefreshStats" }) do
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

    local ok, list = pcall(FindAllOf, "WBP_DesignerHUD_C")
    if ok and list then
        for _, hud in ipairs(list) do
            if Core.IsValidObj(hud) then RefreshDesignerPowerStats(hud) end
        end
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
