-- Eqol Feature: Scroll-to-Rotate Conveyor Belts
-- Allows rotating conveyor belts with the mouse scroll wheel in addition to R.

local Core = require("core")

local Feature = {
    Name = "ConveyorScrollRotate",
}

local PollActive = false
local ConveyorBuilderCls = nil

local function GetActiveConveyorBuilder(pc)
    if not Core.IsValidObj(pc) then return nil end

    if not Core.IsValidObj(ConveyorBuilderCls) then
        ConveyorBuilderCls = Core.FindOrLoadClass("/Script/MainSequence.ConveyorBuilder")
    end
    if not Core.IsValidObj(ConveyorBuilderCls) then return nil end

    for _, prop in ipairs({ "ActiveBuilder", "CurrentBuilder", "Builder" }) do
        local ok, b = pcall(function() return pc[prop] end)
        if ok and Core.IsValidObj(b) and b:IsA(ConveyorBuilderCls) then
            return b
        end
    end

    local okAll, list = pcall(FindAllOf, "ConveyorBuilder")
    if okAll and list then
        for _, b in ipairs(list) do
            if Core.IsValidObj(b) then
                local okPrev, prev = pcall(function() return b.bIsPreviewing or b.bActive end)
                if not okPrev or prev ~= false then
                    return b
                end
            end
        end
    end

    return nil
end

local function StartScrollRotatePoll()
    if PollActive then return end
    PollActive = true

    local function Tick()
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and not pc.bShowMouseCursor then
            local builder = GetActiveConveyorBuilder(pc)
            if Core.IsValidObj(builder) then
                local up, down = false, false
                pcall(function()
                    up = pc:WasInputKeyJustPressed({ KeyName = FName("MouseScrollUp") })
                    down = pc:WasInputKeyJustPressed({ KeyName = FName("MouseScrollDown") })
                end)
                if up then
                    pcall(function() builder:AddRotation(1) end)
                elseif down then
                    pcall(function() builder:AddRotation(-1) end)
                end
            end
        end
        ExecuteInGameThreadWithDelay(16, Tick)
    end

    ExecuteInGameThreadWithDelay(16, Tick)
end

function Feature.Init()
    StartScrollRotatePoll()
end

return Feature
