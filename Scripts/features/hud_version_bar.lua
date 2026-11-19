-- Eqol Feature: HUD Version & FPS Bar
-- Enhances the existing bottom-right Main Sequence version TextBlock in-place
-- (preserving its exact font, size, color, and format) to display:
--   FPS: <game fps> | Eqol v<eqol version> | MS v<main sequence version>

local Core = require("core")

local Feature = {
    Name = "HudVersionBar",
}

local TargetTextBlock = nil
local OriginalMSVersion = nil
local PollRunning = false
local FrameCount = 0
local LastFpsTime = 0.0
local CurrentFps = 0
local LastScanTime = -999.0

local function ExtractMSVersion(str)
    if type(str) ~= "string" then return nil end
    local trimmed = str:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then return nil end
    -- Already formatted by us? Extract the MS v... suffix so we keep the real version
    local existing = trimmed:match("MS%s+v([^|%s]+)")
    if existing and existing ~= "" then
        return existing
    end
    -- Match raw Main Sequence version strings like "0.1.0.109s" or "v0.1.0.109s"
    if trimmed:match("^[vV]?%d+%.%d+%.%d+") and #trimmed <= 24 then
        return trimmed:gsub("^[vV]", "")
    end
    return nil
end

local function FindVersionTextBlock()
    local ok, list = pcall(FindAllOf, "TextBlock")
    if not ok or not list then return nil, nil end
    for i = #list, 1, -1 do
        local tb = list[i]
        if Core.IsValidObj(tb) then
            local okT, txtObj = pcall(function() return tb:GetText() end)
            if okT and txtObj ~= nil then
                local okS, s = pcall(function() return txtObj:ToString() end)
                if okS and type(s) == "string" then
                    local ver = ExtractMSVersion(s)
                    if ver then
                        return tb, ver
                    end
                end
            end
        end
    end
    return nil, nil
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

local function StartLoop()
    if PollRunning then return end
    PollRunning = true
    FrameCount = 0
    LastFpsTime = os.clock()

    local function Tick()
        FrameCount = FrameCount + 1
        local now = os.clock()
        local dt = now - LastFpsTime
        if dt >= 0.5 then
            CurrentFps = math.max(0, math.floor((FrameCount / dt) + 0.5))
            FrameCount = 0
            LastFpsTime = now

            if not Core.IsValidObj(TargetTextBlock) then
                if (now - LastScanTime) >= 1.5 then
                    LastScanTime = now
                    local tb, ver = FindVersionTextBlock()
                    if Core.IsValidObj(tb) and ver then
                        TargetTextBlock = tb
                        OriginalMSVersion = ver
                        EnsureSlotAutoSize(tb)
                        Core.Log(string.format("[HudVersionBar] Hooked version TextBlock (MS v%s)", ver))
                    end
                end
            end

            if Core.IsValidObj(TargetTextBlock) then
                UpdateVersionTextBlock()
            end
        end

        ExecuteInGameThreadAfterFrames(1, Tick)
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

function Feature.Init()
    StartLoop()
end

function Feature.OnMapLoad()
    TargetTextBlock = nil
    LastScanTime = -999.0
    StartLoop()
end

function Feature.OnClientRestart()
    TargetTextBlock = nil
    LastScanTime = -999.0
    StartLoop()
end

return Feature
