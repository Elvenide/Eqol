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
    DesignerHUDClass = "/Game/Blueprints/Widgets/HUDs/Designer/WBP_DesignerHUD.WBP_DesignerHUD_C",
    BPCDesignerClass = "/Game/Blueprints/Player/Designer/BPC_Designer.BPC_Designer_C",
    SolarPanelCDO    = "/Game/Blueprints/Machines/BPO_SolarPanel.Default__BPO_SolarPanel_C",
}

local COLORS = {
    GoldAccent = { R = 0.94, G = 0.65, B = 0.05, A = 1.0 },
    WhiteValue = { R = 0.95, G = 0.96, B = 0.98, A = 1.0 },
    RedValue   = { R = 1.00, G = 0.35, B = 0.35, A = 1.0 },
    GreenValue = { R = 0.30, G = 0.90, B = 0.40, A = 1.0 },
}

local InjectedDesigners = {}    -- hudAddr -> { Hud, PowerText, PowerLabel, LabelColor, SolarEfficiency, InitialLoadedGen, InitialLoadedCons, ResetBaseline }
local BlockClassPowerCache = {} -- blockClsAddr -> { nonSolarGen, solarBaseGen, cons }
local ActorBlockInfoCache = {}  -- actorAddr -> { info = table, clsAddr = number }
local RefreshScheduled = false
local RefreshDesignerPowerStats -- forward declaration

local function FormatPower(kw)
    local val = tonumber(kw) or 0.0
    if math.abs(val) >= 1000.0 then
        return string.format("%.1f MW", val / 1000.0)
    end
    return string.format("%.0f kW", val)
end

local function ReadFPNum(val)
    if type(val) == "number" then return val end
    if val ~= nil then return Core.GetFPFloat(val) end
    return 0.0
end

local function UnwrapStruct(val)
    if val == nil then return nil end
    local ok, inner = pcall(function()
        if type(val.get) == "function" then
            return val:get()
        end
        return val
    end)
    if ok and inner ~= nil then return inner end
    return val
end

local function GetCDOFromUClass(uclass)
    uclass = Core.UnwrapArrayElem(uclass)
    if not Core.IsValidObj(uclass) then return nil end
    local ok, full = pcall(function() return uclass:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    local objPath = full:match("^%S+ (.+)$") or full
    local pkg, clsName = objPath:match("^(.-)%.([^.]+)$")
    if not pkg or not clsName then return nil end
    if string.sub(clsName, 1, 9) == "Default__" then
        return Core.GetCDO(objPath)
    end
    return Core.GetCDO(pkg .. ".Default__" .. clsName)
end

local function HasClassOrName(obj, classPath, nameSubstrings, excludeSubstring)
    if not Core.IsValidObj(obj) then return false end
    if classPath then
        local okIsA, isA = pcall(function() return obj:IsA(classPath) end)
        if okIsA and isA == true then
            return true
        end
    end
    local okCls, clsName = pcall(function() return obj:GetClass():GetFName():ToString() end)
    if not okCls or type(clsName) ~= "string" then
        return false
    end
    if excludeSubstring and string.find(clsName, excludeSubstring, 1, true) then
        return false
    end
    if nameSubstrings then
        for _, sub in ipairs(nameSubstrings) do
            if string.find(clsName, sub, 1, true) then
                return true
            end
        end
    end
    return false
end

local function IsMachineObject(obj)
    if not Core.IsValidObj(obj) then return false end
    if HasClassOrName(obj, "/Script/MainSequence.MachineObject", { "Machine", "SolarPanel", "Reactor", "Generator" }, nil) then
        return true
    end
    local okFn, hasFn = pcall(function()
        return type(obj.GetDisplayMaxPower) == "function" or type(obj.GetDisplayPower) == "function"
    end)
    return okFn and hasFn == true
end

local function IsSolarPanelObject(obj)
    return HasClassOrName(obj, "/Script/MainSequence.SolarPanelObject", { "SolarPanel" }, nil)
end

local function IsProducerObject(obj)
    if IsSolarPanelObject(obj) then return true end
    return HasClassOrName(obj, "/Script/MainSequence.ReactorObject", { "SolarPanel", "Reactor", "Generator" }, "Shield")
end

local function ReadDisplayPower(obj)
    local okMax, maxP = pcall(function()
        return obj.GetDisplayMaxPower and obj:GetDisplayMaxPower() or 0.0
    end)
    if okMax and type(maxP) == "number" and maxP ~= 0 then
        return maxP
    end
    local okCur, curP = pcall(function()
        return obj.GetDisplayPower and obj:GetDisplayPower() or 0.0
    end)
    if okCur and type(curP) == "number" and curP ~= 0 then
        return curP
    end
    return 0.0
end

local function ComputePowerFromObject(obj)
    if not IsMachineObject(obj) then return 0.0, 0.0, 0.0 end

    if IsSolarPanelObject(obj) then
        local rate = 0.0
        pcall(function() rate = ReadFPNum(obj.PowerGenRate) end)
        if rate <= 0 then
            rate = ReadDisplayPower(obj)
        end
        return 0.0, (rate > 0 and rate or 0.0), 0.0
    elseif IsProducerObject(obj) then
        local maxP = ReadDisplayPower(obj)
        local rate = 0.0
        pcall(function() rate = ReadFPNum(obj.PowerGenRate) end)
        return math.max(maxP > 0 and maxP or 0.0, rate > 0 and rate or 0.0), 0.0, 0.0
    else
        local maxP = math.abs(ReadDisplayPower(obj))
        local rate = 0.0
        pcall(function() rate = ReadFPNum(obj.PowerConsumptionRate) end)
        return 0.0, 0.0, math.max(maxP, rate > 0 and rate or 0.0)
    end
end

local function AddMachineEntryPower(entry, nsg, sbg, cons, checkInstance)
    if not entry then return nsg, sbg, cons end
    local mObj = nil
    if Core.IsValidObj(entry) then
        if IsMachineObject(entry) then
            mObj = entry
        else
            mObj = GetCDOFromUClass(entry)
        end
    else
        if checkInstance then
            pcall(function() mObj = Core.UnwrapArrayElem(entry.Machine) end)
        end
        if not Core.IsValidObj(mObj) then
            local mCls = nil
            pcall(function() mCls = entry.Class end)
            if mCls then
                mObj = GetCDOFromUClass(mCls)
            end
        end
    end
    if Core.IsValidObj(mObj) then
        local g, sg, c = ComputePowerFromObject(mObj)
        return nsg + g, sbg + sg, cons + c
    end
    return nsg, sbg, cons
end

local function GetBlockClassPowerInfo(blockCls)
    blockCls = Core.UnwrapArrayElem(blockCls)
    if not Core.IsValidObj(blockCls) then
        return { nonSolarGen = 0.0, solarBaseGen = 0.0, cons = 0.0 }
    end

    local addr = blockCls:GetAddress()
    local cached = BlockClassPowerCache[addr]
    if cached then
        return cached
    end

    local nsg, sbg, cons = 0.0, 0.0, 0.0
    local blockCDO = GetCDOFromUClass(blockCls)
    if Core.IsValidObj(blockCDO) then
        local okDM, defMachines = pcall(function() return blockCDO.DefaultMachines end)
        if okDM and defMachines then
            StationData.ForEachArray(defMachines, function(_, elem)
                nsg, sbg, cons = AddMachineEntryPower(UnwrapStruct(elem), nsg, sbg, cons, true)
            end)
        end

        if nsg == 0.0 and sbg == 0.0 and cons == 0.0 then
            local okGDM, defMachine = pcall(function()
                return blockCDO.GetDefaultMachine and blockCDO:GetDefaultMachine() or nil
            end)
            if okGDM and Core.IsValidObj(defMachine) then
                local g, sg, c = ComputePowerFromObject(defMachine)
                nsg = nsg + g
                sbg = sbg + sg
                cons = cons + c
            end
        end

        if nsg == 0.0 and sbg == 0.0 and cons == 0.0 then
            nsg, sbg, cons = ComputePowerFromObject(blockCDO)
        end
    end

    local info = { nonSolarGen = nsg, solarBaseGen = sbg, cons = cons }
    BlockClassPowerCache[addr] = info
    return info
end

local function EvalPowerInfo(info, solarEfficiency)
    local eff = (type(solarEfficiency) == "number" and solarEfficiency > 0) and solarEfficiency or 1.0
    return (info.nonSolarGen or 0.0) + (info.solarBaseGen or 0.0) * eff, (info.cons or 0.0)
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

local function ScheduleAllDesignersRefresh()
    if RefreshScheduled then return end
    RefreshScheduled = true
    ExecuteInGameThreadWithDelay(40, function()
        RefreshScheduled = false
        for _, st in pairs(InjectedDesigners) do
            if Core.IsValidObj(st.Hud) then
                RefreshDesignerPowerStats(st.Hud)
            end
        end
    end)
end

local function ResolveStationSolarEfficiency(frame, pg)
    local eff = nil
    if Core.IsValidObj(pg) then
        local okProds, prods = pcall(function() return pg.Producers end)
        if okProds and prods then
            StationData.ForEachArray(prods, function(_, elem)
                if eff ~= nil then return end
                local prod = Core.UnwrapArrayElem(elem)
                if not IsSolarPanelObject(prod) then return end

                local rate = 0.0
                pcall(function() rate = ReadFPNum(prod.PowerGenRate) end)
                local maxP = 0.0
                if prod.GetDisplayMaxPower then
                    local okMaxP, mp = pcall(function() return prod:GetDisplayMaxPower() end)
                    if okMaxP and type(mp) == "number" then maxP = mp end
                end
                if rate > 0 and maxP > 0 then
                    eff = maxP / rate
                    return
                end

                local okDE, deVal = pcall(function() return prod.DistanceEfficiency end)
                if okDE and deVal ~= nil then
                    local de = ReadFPNum(deVal)
                    if de > 0 then
                        eff = de
                    end
                end
            end)
        end
    end

    if eff ~= nil then return eff end

    -- Fallback when the station has no existing solar panels: compute from distance to sun and solar CDO bounds
    if Core.IsValidObj(frame) and frame.GetDistanceToSun then
        local okD, rawDist = pcall(function() return frame:GetDistanceToSun() end)
        local dist = okD and ReadFPNum(rawDist) or 0.0
        if dist > 0 then
            local solarCDO = Core.GetCDO(PATHS.SolarPanelCDO)
            if Core.IsValidObj(solarCDO) then
                local minDist, maxDist, minEff, maxEff = 0.0, 0.0, 0.0, 1.0
                pcall(function()
                    minDist = ReadFPNum(solarCDO.MinDistance)
                    maxDist = ReadFPNum(solarCDO.MaxDistance)
                    minEff  = ReadFPNum(solarCDO.MinEfficiency)
                    maxEff  = ReadFPNum(solarCDO.MaxEfficiency)
                end)
                if maxEff > 0 and maxDist > minDist then
                    local t = Core.Clamp((dist - minDist) / (maxDist - minDist), 0.0, 1.0)
                    eff = maxEff + t * (minEff - maxEff)
                    if eff > 0 then
                        return eff
                    end
                end
            end
        end
    end

    return 1.0
end

local function ComputeDesignerPower(designerHud, st)
    local designer = ResolveDesignerObject(designerHud)
    if not Core.IsValidObj(designer) then return 0.0, 0.0 end

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
    local pg = nil
    if isStationFrame and frame.GetPowerGrid then
        local okPG, foundPG = pcall(function() return frame:GetPowerGrid() end)
        if okPG and Core.IsValidObj(foundPG) then
            pg = foundPG
            pgGen = ReadFPNum(pg.MaxProduction)
            pgCons = ReadFPNum(pg.MaxConsumption)
        end
    end

    local solarEfficiency = 1.0
    if isStationFrame then
        if st and type(st.SolarEfficiency) == "number" then
            solarEfficiency = st.SolarEfficiency
        else
            solarEfficiency = ResolveStationSolarEfficiency(frame, pg)
            if st then
                st.SolarEfficiency = solarEfficiency
            end
        end
    end

    local previewPendingGen, previewPendingCons = 0.0, 0.0
    local previewLoadedGen, previewLoadedCons = 0.0, 0.0
    local previewCount = 0

    local okPreview, previewBlocks = pcall(function()
        if Core.IsValidObj(designer.Visualizer) then
            return designer.Visualizer.PreviewBlocks
        end
        return nil
    end)
    if okPreview and previewBlocks then
        StationData.ForEachArray(previewBlocks, function(_, elem)
            local actor = Core.UnwrapArrayElem(elem)
            if not Core.IsValidObj(actor) then return end

            previewCount = previewCount + 1
            local aAddr = actor:GetAddress()
            local cached = ActorBlockInfoCache[aAddr]
            local info = cached and cached.info or nil
            if not info then
                local blockCls = nil
                pcall(function() blockCls = Core.UnwrapArrayElem(actor.BlockClass) end)
                if not Core.IsValidObj(blockCls) then
                    pcall(function()
                        if Core.IsValidObj(actor.BlockObject) then
                            blockCls = actor.BlockObject:GetClass()
                        end
                    end)
                end
                info = GetBlockClassPowerInfo(blockCls)
                ActorBlockInfoCache[aAddr] = {
                    info = info,
                    clsAddr = Core.IsValidObj(blockCls) and blockCls:GetAddress() or 0,
                }
            end

            local isPending = false
            local okPend, pendRes = pcall(function()
                if actor.IsDesignerPending then
                    return actor:IsDesignerPending()
                end
                return actor.bPending == true
            end)
            if okPend then
                isPending = (pendRes == true)
            end

            local g, c = EvalPowerInfo(info, solarEfficiency)
            if isPending then
                previewPendingGen = previewPendingGen + g
                previewPendingCons = previewPendingCons + c
            else
                previewLoadedGen = previewLoadedGen + g
                previewLoadedCons = previewLoadedCons + c
            end
        end)
    end

    if st then
        if st.InitialLoadedGen == nil or (st.ResetBaseline == true and previewPendingGen == 0.0 and previewPendingCons == 0.0) then
            st.InitialLoadedGen = previewLoadedGen
            st.InitialLoadedCons = previewLoadedCons
            st.ResetBaseline = false
        end
    end

    local totalGen, totalCons = 0.0, 0.0
    if isStationFrame then
        local baseLoadedGen = st and st.InitialLoadedGen or previewLoadedGen
        local baseLoadedCons = st and st.InitialLoadedCons or previewLoadedCons
        local deltaGen = (previewLoadedGen - baseLoadedGen) + previewPendingGen
        local deltaCons = (previewLoadedCons - baseLoadedCons) + previewPendingCons
        totalGen = math.max(0.0, pgGen + deltaGen)
        totalCons = math.max(0.0, pgCons + deltaCons)
    else
        totalGen = previewLoadedGen + previewPendingGen
        totalCons = previewLoadedCons + previewPendingCons
    end

    local diag = string.format(
        "DesignerPowerStats: gen=%.1f cons=%.1f (station=%s eff=%.2f pg=%.1f/%.1f preview=%d loaded=%.1f/%.1f pend=%.1f/%.1f)",
        totalGen, totalCons, tostring(isStationFrame), solarEfficiency, pgGen, pgCons,
        previewCount, previewLoadedGen, previewLoadedCons, previewPendingGen, previewPendingCons
    )
    return totalGen, totalCons, diag
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

RefreshDesignerPowerStats = function(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    local st = InjectedDesigners[addr]

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
    end

    local gen, cons, diag = ComputeDesignerPower(hud, st)
    if st.LastGen ~= gen or st.LastCons ~= cons then
        st.LastGen = gen
        st.LastCons = cons
        if diag then
            Core.Log(diag)
        end
    end
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
        Feature.RegisterHooks()
        ExecuteInGameThreadWithDelay(150, function()
            if Core.IsValidObj(hud) then
                RefreshDesignerPowerStats(hud)
            end
        end)
    end,
}

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "DesignerHUD_RefreshStats",
        PATHS.DesignerHUDClass .. ":RefreshStats",
        function(Context)
            local hud = Context:get()
            if Core.IsValidObj(hud) then
                ScheduleAllDesignersRefresh()
            end
        end
    )

    Core.TryRegisterHook(
        "BPCDesigner_Confirm",
        PATHS.BPCDesignerClass .. ":Confirm",
        function()
            ActorBlockInfoCache = {}
            for _, st in pairs(InjectedDesigners) do
                st.ResetBaseline = true
                st.SolarEfficiency = nil
            end
            ScheduleAllDesignersRefresh()
        end
    )

    Core.TryRegisterHook(
        "BPCDesigner_RemoveBlock",
        PATHS.BPCDesignerClass .. ":RemoveBlock",
        function()
            ScheduleAllDesignersRefresh()
        end
    )
end

function Feature.OnClientRestart()
    Feature.RegisterHooks()
end

function Feature.PruneCaches()
    ActorBlockInfoCache = {}
    for addr, st in pairs(InjectedDesigners) do
        if not Core.IsValidObj(st.PowerText) then
            InjectedDesigners[addr] = nil
        end
    end
end

function Feature.Init()
    Feature.RegisterHooks()
end

return Feature
