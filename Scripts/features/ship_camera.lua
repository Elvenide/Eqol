-- Eqol Feature: Ship 3rd-Person Perspective & Scroll Zoom
-- Configurable keybind (default V) to toggle 1st/3rd person while piloting a ship,
-- plus mouse scroll wheel to adjust 3rd-person camera distance.

local Core = require("core")

local Feature = {
    Name = "ShipCamera",
}

local MIN_ARM_DIST = 600.0
local MAX_ARM_DIST = 8000.0
local ZOOM_STEP = 350.0

local IsThirdPerson = false
local ThirdPersonDist = 2200.0
local ScrollPollActive = false

local function GetPilotedShipActor(pc)
    if not Core.IsValidObj(pc) then return nil, nil end
    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return nil, nil end
    local shipObj = playerObj.PilotedShip
    if not Core.IsValidObj(shipObj) then return nil, nil end

    local shipActor = nil
    for _, fn in ipairs({ "GetActor", "GetSpawnedActor" }) do
        local ok, a = pcall(function() return shipObj[fn](shipObj) end)
        if ok and Core.IsValidObj(a) then shipActor = a; break end
    end
    if not Core.IsValidObj(shipActor) then
        pcall(function() shipActor = shipObj.Actor or shipObj.ShipActor end)
    end
    if not Core.IsValidObj(shipActor) then
        local okPawn, pawn = pcall(function() return pc.Pawn end)
        if okPawn and Core.IsValidObj(pawn) then shipActor = pawn end
    end
    return shipActor, shipObj
end

local function ApplyShipCameraState(pc)
    local shipActor, shipObj = GetPilotedShipActor(pc)
    if not Core.IsValidObj(shipActor) then return end

    -- Try native SpringArm / Camera properties if exposed on BP_PlayerShip
    local springArm = nil
    for _, prop in ipairs({ "SpringArm", "CameraBoom", "ThirdPersonSpringArm", "ExternalSpringArm" }) do
        local ok, comp = pcall(function() return shipActor[prop] end)
        if ok and Core.IsValidObj(comp) then
            springArm = comp
            break
        end
    end

    if Core.IsValidObj(springArm) then
        pcall(function()
            if IsThirdPerson then
                springArm.TargetArmLength = ThirdPersonDist
            else
                springArm.TargetArmLength = 0.0
            end
        end)
    end

    local cam = nil
    for _, prop in ipairs({ "ThirdPersonCamera", "ExternalCamera", "Camera", "ShipCamera" }) do
        local ok, comp = pcall(function() return shipActor[prop] end)
        if ok and Core.IsValidObj(comp) then
            cam = comp
            break
        end
    end

    if Core.IsValidObj(cam) and not Core.IsValidObj(springArm) then
        pcall(function()
            if IsThirdPerson then
                cam:K2_SetRelativeLocation({ X = -ThirdPersonDist, Y = 0.0, Z = ThirdPersonDist * 0.28 }, false, nil, false)
            else
                cam:K2_SetRelativeLocation({ X = 0.0, Y = 0.0, Z = 0.0 }, false, nil, false)
            end
        end)
    end

    if Core.IsValidObj(shipObj) then
        pcall(function()
            if shipObj.SetViewedExternally then
                shipObj:SetViewedExternally(IsThirdPerson)
            end
        end)
    end
end

local function ToggleShipPerspective()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end
    local shipActor = GetPilotedShipActor(pc)
    if not Core.IsValidObj(shipActor) then return end

    IsThirdPerson = not IsThirdPerson
    ApplyShipCameraState(pc)
end

local function StartScrollPoll()
    if ScrollPollActive then return end
    ScrollPollActive = true

    local function Tick()
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and IsThirdPerson and not pc.bShowMouseCursor then
            local shipActor = GetPilotedShipActor(pc)
            if Core.IsValidObj(shipActor) then
                local up, down = false, false
                pcall(function()
                    up = pc:WasInputKeyJustPressed({ KeyName = FName("MouseScrollUp") })
                    down = pc:WasInputKeyJustPressed({ KeyName = FName("MouseScrollDown") })
                end)
                if up then
                    ThirdPersonDist = Core.Clamp(ThirdPersonDist - ZOOM_STEP, MIN_ARM_DIST, MAX_ARM_DIST)
                    ApplyShipCameraState(pc)
                elseif down then
                    ThirdPersonDist = Core.Clamp(ThirdPersonDist + ZOOM_STEP, MIN_ARM_DIST, MAX_ARM_DIST)
                    ApplyShipCameraState(pc)
                end
            end
        end
        ExecuteInGameThreadWithDelay(16, Tick)
    end

    ExecuteInGameThreadWithDelay(16, Tick)
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "ShipPerspectiveKey",
        DefaultKey  = "V",
        MappingName = "Eqol_ShipPerspective",
        Label       = "Ship Camera Perspective",
        OnPress     = ToggleShipPerspective,
    })
    StartScrollPoll()
end

function Feature.OnClientRestart()
    IsThirdPerson = false
end

return Feature
