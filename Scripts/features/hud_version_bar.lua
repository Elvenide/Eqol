-- Eqol Feature: HUD Version & FPS Bar
-- Enhances the existing bottom-right Main Sequence version TextBlock in-place
-- (preserving its exact font, size, color, and format) to display:
--   FPS: <game fps> | Eqol v<eqol version> | MS v<main sequence version>

local Core = require("core")

local Feature = {
    Name        = "HudVersionBar",
    DisplayName = "HUD FPS & Version Bar",
    Description = "Displays live FPS and Eqol version alongside the game version in the bottom-right HUD.",
}

local TargetTextBlock = nil
local OriginalMSVersion = nil
local OriginalMSRawText = nil
local PollRunning = false
local FrameCount = 0
local LastFpsTime = 0.0
local CurrentFps = 0
local LastScanTime = -999.0

local function ExtractMSVersion(str)
    if type(str) ~= "string" then return nil, nil end
    local trimmed = str:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then return nil, nil end
    -- Already formatted by us? Extract the MS v... suffix so we keep the real version
    local existing = trimmed:match("MS%s+v([^|%s]+)")
    if existing and existing ~= "" then
        return existing, nil
    end
    -- Match raw Main Sequence version strings like "0.1.0.109s" or "v0.1.0.109s"
    if trimmed:match("^[vV]?%d+%.%d+%.%d+") and #trimmed <= 24 then
        return trimmed:gsub("^[vV]", ""), trimmed
    end
    return nil, nil
end

local function IsVersionOverlayTextBlock(tb)
    local isVis = false
    pcall(function() isVis = (tb:IsVisible() == true) end)
    if not isVis then return false end

    -- Narrow match to the persistent HUD / Version / MainMenu overlay so unrelated semver UI labels
    -- (save lists, server browser entries, patch notes) are never overwritten.
    local okFull, fullName = pcall(function() return tb:GetFullName():lower() end)
    if okFull and type(fullName) == "string" then
        if fullName:find("save", 1, true) or fullName:find("server", 1, true)
            or fullName:find("changelog", 1, true) or fullName:find("patch", 1, true)
            or fullName:find("codex", 1, true) or fullName:find("chat", 1, true)
        then
            return false
        end
    end
    return true
end

local CachedGameplayStaticsCDO = nil

local function TryExtractVersionFromTextObj(tb)
    if not Core.IsValidObj(tb) or not tb.GetText or not IsVersionOverlayTextBlock(tb) then
        return nil, nil, nil
    end
    local okT, txtObj = pcall(function() return tb:GetText() end)
    if okT and txtObj ~= nil then
        local okS, s = pcall(function() return txtObj:ToString() end)
        if okS and type(s) == "string" then
            local ver, rawTxt = ExtractMSVersion(s)
            if ver then
                return tb, ver, rawTxt
            end
        end
    end
    return nil, nil, nil
end

-- Walk a UUserWidget/UPanelWidget subtree via native UMG GetRootWidget + GetChildrenCount/GetChildAt
-- (works in Shipping builds where WidgetTree is stripped and when "Is Variable" is unchecked).
local function FindVersionTextInWidgetTree(rootWidget, maxDepth)
    if not Core.IsValidObj(rootWidget) then return nil, nil, nil end
    local limit = maxDepth or 8
    local visited = {}
    local queue = { { w = rootWidget, d = 0 } }
    local head = 1
    local maxNodes = 160

    while head <= #queue and head <= maxNodes do
        local item = queue[head]
        head = head + 1
        local w = item.w
        local d = item.d
        if Core.IsValidObj(w) then
            local addr = w:GetAddress()
            if not visited[addr] then
                visited[addr] = true
                -- Check if this node itself is a TextBlock with the MS version string
                if w.GetText and w.SetText then
                    local tb, ver, rawTxt = TryExtractVersionFromTextObj(w)
                    if Core.IsValidObj(tb) then
                        return tb, ver, rawTxt
                    end
                end
                if d < limit then
                    -- UserWidget -> GetRootWidget()
                    if w.GetRootWidget then
                        local okR, rw = pcall(function() return w:GetRootWidget() end)
                        if okR and Core.IsValidObj(rw) then
                            queue[#queue + 1] = { w = rw, d = d + 1 }
                        end
                    end
                    -- PanelWidget / ContentWidget -> GetChildrenCount() + GetChildAt(i)
                    if w.GetChildrenCount and w.GetChildAt then
                        local okN, n = pcall(function() return tonumber(w:GetChildrenCount()) or 0 end)
                        if okN and n > 0 then
                            local cap = math.min(n, 32)
                            for i = 0, cap - 1 do
                                local okC, child = pcall(function() return w:GetChildAt(i) end)
                                if okC and Core.IsValidObj(child) then
                                    queue[#queue + 1] = { w = child, d = d + 1 }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, nil, nil
end

local function FindVersionTextBlockInVersionWidget(verW)
    if not Core.IsValidObj(verW) then return nil, nil, nil end
    local tb = nil
    pcall(function()
        local txtW = verW.WBP_Text
        if Core.IsValidObj(txtW) and Core.IsValidObj(txtW.TextBlock) then
            tb = txtW.TextBlock
        elseif Core.IsValidObj(verW.TextBlock) then
            tb = verW.TextBlock
        end
    end)
    if Core.IsValidObj(tb) then
        local foundTb, ver, rawTxt = TryExtractVersionFromTextObj(tb)
        if Core.IsValidObj(foundTb) then return foundTb, ver, rawTxt end
    end
    return FindVersionTextInWidgetTree(verW, 6)
end

-- Verified widget hierarchy in Main Sequence:
-- WBP_CharacterHUD_C / WBP_MainMenu_C -> WBP_Version (WBP_Version_C) -> WBP_Text -> TextBlock
-- Uses FindAllOf("WBP_Version_C") (only 1-2 instances exist in the entire game) + native UMG tree walk.
local function FindVersionTextBlock(hintWidget)
    local okAll, verList = pcall(FindAllOf, "WBP_Version_C")
    if okAll and verList then
        for i = #verList, 1, -1 do
            local vw = verList[i]
            if Core.IsValidObj(vw) then
                local tb, ver, rawTxt = FindVersionTextBlockInVersionWidget(vw)
                if Core.IsValidObj(tb) then return tb, ver, rawTxt end
            end
        end
    end
    if Core.IsValidObj(hintWidget) then
        local tb, ver, rawTxt = FindVersionTextInWidgetTree(hintWidget, 8)
        if Core.IsValidObj(tb) then return tb, ver, rawTxt end
    end
    for _, clsName in ipairs({ "WBP_CharacterHUD_C", "WBP_MainMenu_C" }) do
        local okF, host = pcall(FindFirstOf, clsName)
        if okF and Core.IsValidObj(host) then
            local tb, ver, rawTxt = FindVersionTextInWidgetTree(host, 8)
            if Core.IsValidObj(tb) then return tb, ver, rawTxt end
        end
    end
    return nil, nil, nil
end

local function UpdateVersionTextBlock()
    if not Core.IsValidObj(TargetTextBlock) or not OriginalMSVersion then return false end
    local label = string.format("FPS: %d | Eqol v%s | MS v%s", CurrentFps, tostring(Core.VERSION or "0.1.0"), OriginalMSVersion)
    local ok = pcall(function()
        TargetTextBlock:SetText(Core.MakeText(label))
    end)
    return ok
end

local function EnsureSlotAutoSize(tb)
    if not Core.IsValidObj(tb) then return end
    pcall(function()
        if tb.Slot and Core.IsValidObj(tb.Slot) and tb.Slot.SetAutoSize then
            tb.Slot:SetAutoSize(true)
        end
    end)
end

local SCAN_RETRY_SECONDS = 8.0 -- Safety-net FindAllOf("TextBlock") interval (>= 8s per learning.md §7)

local function TryHookVersionTextBlock(hintWidget)
    if Core.IsValidObj(TargetTextBlock) then return true end
    LastScanTime = os.clock()
    local tb, ver, rawTxt = FindVersionTextBlock(hintWidget)
    if Core.IsValidObj(tb) and ver then
        TargetTextBlock = tb
        OriginalMSVersion = ver
        if rawTxt then
            OriginalMSRawText = rawTxt
        end
        EnsureSlotAutoSize(tb)
        Core.Log(string.format("[HudVersionBar] Hooked version TextBlock (MS v%s)", ver))
        return true
    end
    return false
end

local function SampleNativeFps()
    if not Core.IsValidObj(CachedGameplayStaticsCDO) then
        CachedGameplayStaticsCDO = Core.GetCDO("/Script/Engine.Default__GameplayStatics")
    end
    local pc = Core.GetLocalPlayerController()
    if Core.IsValidObj(CachedGameplayStaticsCDO) and Core.IsValidObj(pc) then
        local okDt, dt = pcall(function() return CachedGameplayStaticsCDO:GetWorldDeltaSeconds(pc) end)
        if okDt and type(dt) == "number" and dt > 0.0001 and dt < 2.0 then
            return math.max(1, math.floor((1.0 / dt) + 0.5))
        end
    end
    return CurrentFps
end

local function StartLoop()
    if PollRunning then return end
    PollRunning = true

    -- Poll at 2 Hz (every 500ms) reading Unreal's native GetWorldDeltaSeconds instead of
    -- running a 120+ Hz every-frame Lua callback just to count frames!
    local function Tick()
        if not Core.IsFeatureEnabled("HudVersionBar") then
            PollRunning = false
            return
        end
        CurrentFps = SampleNativeFps()
        local now = os.clock()
        if not Core.IsValidObj(TargetTextBlock) then
            if (now - LastScanTime) >= SCAN_RETRY_SECONDS then
                TryHookVersionTextBlock()
            end
        end
        if Core.IsValidObj(TargetTextBlock) then
            UpdateVersionTextBlock()
        end
        ExecuteInGameThreadWithDelay(500, Tick)
    end

    ExecuteInGameThreadWithDelay(500, Tick)
end

-- Trigger a prompt one-shot scan when major HUD/menu widgets construct
local function ScheduleHintScan(w)
    if not Core.IsFeatureEnabled("HudVersionBar") then return end
    for _, delayMs in ipairs({ 200, 1000 }) do
        ExecuteInGameThreadWithDelay(delayMs, function()
            if Core.IsFeatureEnabled("HudVersionBar") and not Core.IsValidObj(TargetTextBlock) then
                TryHookVersionTextBlock(w)
            end
        end)
    end
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = ScheduleHintScan,
    WBP_MainMenu_C     = ScheduleHintScan,
}

function Feature.OnToggle(enabled)
    if enabled then
        StartLoop()
    else
        local restoreText = OriginalMSRawText or OriginalMSVersion
        if Core.IsValidObj(TargetTextBlock) and restoreText then
            pcall(function() TargetTextBlock:SetText(Core.MakeText(restoreText)) end)
        end
    end
end

function Feature.Init()
    if Core.IsFeatureEnabled("HudVersionBar") then
        StartLoop()
    end
end

function Feature.OnMapLoad()
    TargetTextBlock = nil
    LastScanTime = -999.0
    if Core.IsFeatureEnabled("HudVersionBar") then StartLoop() end
end

function Feature.OnClientRestart()
    TargetTextBlock = nil
    LastScanTime = -999.0
    if Core.IsFeatureEnabled("HudVersionBar") then StartLoop() end
end

return Feature
