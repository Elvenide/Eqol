-- Eqol Feature: Ship 3rd-Person Perspective & Scroll Zoom
-- Configurable keybind (default H) to toggle 1st/3rd person while piloting a ship,
-- plus mouse scroll wheel to adjust 3rd-person camera distance.

local Core = require("core")

local Feature = {
    Name        = "ShipCamera",
    DisplayName = "Ship 3rd-Person Camera & Zoom",
    Description = "Hotkey (default H) for 3rd-person ship perspective with scroll-wheel zoom.",
}

local MIN_ZOOM_MULT = 0.65
local MAX_ZOOM_MULT = 3.00
local ZOOM_MULT_STEP = 0.15

local IsThirdPerson = false
local ZoomMultiplier = 1.0
local ScrollPollActive = false
local SavedOriginalCamera = {} -- shipActorAddr -> { ShipActor, ShipObj, SpringArm, TargetArmLength, Cam, RelativeLocation, RelativeRotation, ShipRadius }
local ActiveShipAddr = nil

-- Hoisted FName key tables (avoids per-frame FName allocation; see learning.md §8)
local KEY_MOUSE_WHEEL_AXIS = nil
local KEY_SCROLL_UP = nil
local KEY_SCROLL_DOWN = nil

local function EnsureScrollKeyTables()
    if KEY_MOUSE_WHEEL_AXIS == nil then
        pcall(function() KEY_MOUSE_WHEEL_AXIS = { KeyName = FName("MouseWheelAxis") } end)
        pcall(function() KEY_SCROLL_UP = { KeyName = FName("MouseScrollUp") } end)
        pcall(function() KEY_SCROLL_DOWN = { KeyName = FName("MouseScrollDown") } end)
    end
end

local CachedSpringArmCls = nil
local CachedCameraCls = nil

local function FindFirstComponentOfClass(actor, clsPath, cachedCls)
    if not Core.IsValidObj(actor) or not actor.K2_GetComponentsByClass then return nil, cachedCls end
    local cls = cachedCls
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(clsPath)
    end
    if not Core.IsValidObj(cls) then return nil, cls end
    local found = nil
    pcall(function()
        local arr = actor:K2_GetComponentsByClass(cls)
        if arr then
            local len = arr.GetArrayNum and arr:GetArrayNum() or #arr
            for i = 1, len do
                local c = Core.UnwrapArrayElem(arr[i])
                if Core.IsValidObj(c) then
                    found = c
                    break
                end
            end
        end
    end)
    return found, cls
end

local function FindShipCameraComponents(shipActor, pc)
    local actorsToCheck = {}
    local seen = {}
    local function addActor(a)
        if Core.IsValidObj(a) then
            local addr = a:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                actorsToCheck[#actorsToCheck + 1] = a
            end
        end
    end

    addActor(shipActor)
    if Core.IsValidObj(pc) then
        pcall(function()
            if pc.GetViewTarget then addActor(pc:GetViewTarget()) end
        end)
        pcall(function() addActor(pc.Pawn) end)
    end

    local springArm = nil
    local cam = nil

    for _, actor in ipairs(actorsToCheck) do
        if not Core.IsValidObj(springArm) then
            for _, prop in ipairs({ "SpringArm", "CameraBoom", "ThirdPersonSpringArm", "ExternalSpringArm" }) do
                local ok, comp = pcall(function() return actor[prop] end)
                if ok and Core.IsValidObj(comp) then
                    springArm = comp
                    break
                end
            end
        end
        if not Core.IsValidObj(springArm) then
            springArm, CachedSpringArmCls = FindFirstComponentOfClass(actor, "/Script/Engine.SpringArmComponent", CachedSpringArmCls)
        end

        if not Core.IsValidObj(cam) then
            for _, prop in ipairs({ "ThirdPersonCamera", "ExternalCamera", "Camera", "ShipCamera", "CameraComponent" }) do
                local ok, comp = pcall(function() return actor[prop] end)
                if ok and Core.IsValidObj(comp) then
                    cam = comp
                    break
                end
            end
        end
        if not Core.IsValidObj(cam) then
            cam, CachedCameraCls = FindFirstComponentOfClass(actor, "/Script/Engine.CameraComponent", CachedCameraCls)
        end

        if Core.IsValidObj(springArm) and Core.IsValidObj(cam) then break end
    end

    return springArm, cam
end

local function MeasureShipRadiusCm(shipActor)
    local radius = 1400.0
    if not Core.IsValidObj(shipActor) then return radius end

    -- 1. Try native GetActorBounds(false, Origin, BoxExtent) which spans all custom-built blocks on the ship
    local gotBounds = false
    pcall(function()
        if shipActor.GetActorBounds then
            local outOrigin = {}
            local outExtent = {}
            shipActor:GetActorBounds(false, outOrigin, outExtent)
            local ex = math.abs(tonumber(outExtent.X) or 0.0)
            local ey = math.abs(tonumber(outExtent.Y) or 0.0)
            local ez = math.abs(tonumber(outExtent.Z) or 0.0)
            local r = math.sqrt(ex * ex + ey * ey + ez * ez)
            if r > 150.0 then
                radius = r
                gotBounds = true
            end
        end
    end)

    -- 2. Fallback: scan StaticMeshComponents' local bounds if GetActorBounds returned zero/small
    if not gotBounds and shipActor.K2_GetComponentsByClass then
        pcall(function()
            local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
            if not Core.IsValidObj(smCls) then return end
            local arr = shipActor:K2_GetComponentsByClass(smCls)
            if not arr then return end
            local len = arr.GetArrayNum and arr:GetArrayNum() or #arr
            local maxR = 0.0
            for i = 1, len do
                local c = Core.UnwrapArrayElem(arr[i])
                if Core.IsValidObj(c) then
                    local rl = c.RelativeLocation
                    local lx = rl and (tonumber(rl.X) or 0.0) or 0.0
                    local ly = rl and (tonumber(rl.Y) or 0.0) or 0.0
                    local lz = rl and (tonumber(rl.Z) or 0.0) or 0.0
                    local ext = 100.0
                    local sm = c.StaticMesh
                    if Core.IsValidObj(sm) and sm.ExtendedBounds and sm.ExtendedBounds.SphereRadius then
                        ext = tonumber(sm.ExtendedBounds.SphereRadius) or 100.0
                    end
                    local d = math.sqrt(lx * lx + ly * ly + lz * lz) + ext
                    if d > maxR then maxR = d end
                end
            end
            if maxR > 150.0 then
                radius = maxR
            end
        end)
    end

    return math.max(800.0, radius)
end

local function SnapshotOriginalCamera(shipActor, shipObj, springArm, cam)
    if not Core.IsValidObj(shipActor) then return nil end
    local addr = shipActor:GetAddress()
    local saved = SavedOriginalCamera[addr]
    if saved then return saved end

    saved = {
        ShipActor = shipActor,
        ShipObj = shipObj,
        SpringArm = springArm,
        TargetArmLength = 0.0,
        Cam = cam,
        RelativeLocation = { X = 0.0, Y = 0.0, Z = 0.0 },
        RelativeRotation = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
        ShipRadius = MeasureShipRadiusCm(shipActor),
    }
    if Core.IsValidObj(springArm) then
        pcall(function()
            if type(springArm.TargetArmLength) == "number" then
                saved.TargetArmLength = springArm.TargetArmLength
            end
        end)
    end
    if Core.IsValidObj(cam) then
        pcall(function()
            local rel = cam.RelativeLocation
            if rel and type(rel.X) == "number" then
                saved.RelativeLocation = { X = rel.X, Y = rel.Y or 0.0, Z = rel.Z or 0.0 }
            end
            local rot = cam.RelativeRotation
            if rot and type(rot.Yaw) == "number" then
                saved.RelativeRotation = { Pitch = rot.Pitch or 0.0, Yaw = rot.Yaw or 0.0, Roll = rot.Roll or 0.0 }
            end
        end)
    end
    SavedOriginalCamera[addr] = saved
    return saved
end

local function RestoreShipCameraSnapshot(saved)
    if not saved then return end
    if Core.IsValidObj(saved.SpringArm) then
        pcall(function() saved.SpringArm.TargetArmLength = saved.TargetArmLength end)
    elseif Core.IsValidObj(saved.Cam) then
        pcall(function() saved.Cam:K2_SetRelativeLocation(saved.RelativeLocation, false, {}, false) end)
    end
    if Core.IsValidObj(saved.ShipObj) then
        pcall(function()
            if saved.ShipObj.SetViewedExternally then
                saved.ShipObj:SetViewedExternally(false)
            end
        end)
    end
end

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
        pcall(function()
            local actors = shipObj.Actors
            if actors then
                local len = actors.GetArrayNum and actors:GetArrayNum() or #actors
                for i = 1, len do
                    local a = Core.UnwrapArrayElem(actors[i])
                    if Core.IsValidObj(a) then shipActor = a; break end
                end
            end
        end)
    end
    if not Core.IsValidObj(shipActor) then
        pcall(function() shipActor = shipObj.Actor or shipObj.ShipActor end)
    end
    if not Core.IsValidObj(shipActor) then
        pcall(function()
            if pc.GetViewTarget then
                local vt = pc:GetViewTarget()
                if Core.IsValidObj(vt) then shipActor = vt end
            end
        end)
    end
    if not Core.IsValidObj(shipActor) then
        local okPawn, pawn = pcall(function() return pc.Pawn end)
        if okPawn and Core.IsValidObj(pawn) then
            shipActor = pawn
        end
    end
    return shipActor, shipObj
end

local function IsPilotingShipNow()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end
    if Core.IsAnyBlockingMenuOpen and Core.IsAnyBlockingMenuOpen() then return false end
    local ok, po = pcall(function() return pc.PlayerObject end)
    return ok and Core.IsValidObj(po) and Core.IsValidObj(po.PilotedShip)
end

local function ApplyShipCameraState(pc)
    local shipActor, shipObj = GetPilotedShipActor(pc)
    if not Core.IsValidObj(shipActor) then return end

    local newAddr = shipActor:GetAddress()
    if ActiveShipAddr and ActiveShipAddr ~= newAddr and SavedOriginalCamera[ActiveShipAddr] then
        -- Restore the previous ship's original camera snapshot on direct Ship A -> Ship B switch
        RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
    end

    local springArm, cam = FindShipCameraComponents(shipActor, pc)
    local saved = SnapshotOriginalCamera(shipActor, shipObj, springArm, cam)
    ActiveShipAddr = newAddr

    -- Re-measure ship radius when toggling into 3P in case the ship was redesigned/modified
    if IsThirdPerson and saved then
        saved.ShipRadius = MeasureShipRadiusCm(shipActor)
    end
    local shipRadius = (saved and saved.ShipRadius) or 1400.0
    local backDist = shipRadius * 1.65 * ZoomMultiplier
    local upHeight = shipRadius * 0.48 * ZoomMultiplier

    Core.Log(string.format("[ShipCamera] Apply 3P=%s radius=%.0f back=%.0f up=%.0f actor=%s arm=%s cam=%s",
        tostring(IsThirdPerson), shipRadius, backDist, upHeight,
        Core.IsValidObj(shipActor) and shipActor:GetClass():GetFName():ToString() or "nil",
        tostring(Core.IsValidObj(springArm)), tostring(Core.IsValidObj(cam))))

    if Core.IsValidObj(springArm) then
        pcall(function()
            if IsThirdPerson then
                springArm.TargetArmLength = backDist
            else
                springArm.TargetArmLength = saved and saved.TargetArmLength or 0.0
            end
        end)
    end

    if Core.IsValidObj(cam) and not Core.IsValidObj(springArm) then
        pcall(function()
            local orig = saved and saved.RelativeLocation or { X = 0.0, Y = 0.0, Z = 0.0 }
            local rot = saved and saved.RelativeRotation or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
            if IsThirdPerson then
                -- Offset cleanly behind and above the entire ship bounding sphere along the camera's true local basis
                -- so the camera is always outside custom-built ships with the forward flight path unobstructed
                local yawRad = math.rad(rot.Yaw or 0.0)
                local pitchRad = math.rad(rot.Pitch or 0.0)
                local fwdX = math.cos(pitchRad) * math.cos(yawRad)
                local fwdY = math.cos(pitchRad) * math.sin(yawRad)
                local fwdZ = math.sin(pitchRad)
                local upX = -math.sin(pitchRad) * math.cos(yawRad)
                local upY = -math.sin(pitchRad) * math.sin(yawRad)
                local upZ = math.cos(pitchRad)

                local tx = orig.X - fwdX * backDist + upX * upHeight
                local ty = orig.Y - fwdY * backDist + upY * upHeight
                local tz = orig.Z - fwdZ * backDist + upZ * upHeight
                cam:K2_SetRelativeLocation({ X = tx, Y = ty, Z = tz }, false, {}, false)
            else
                cam:K2_SetRelativeLocation(orig, false, {}, false)
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

local ScrollPollGen = 0

-- On-demand frame-synchronized scroll loop: runs ONLY while IsThirdPerson is active (learning.md §8)
local function StartScrollPoll()
    if ScrollPollActive then return end
    ScrollPollActive = true
    ScrollPollGen = ScrollPollGen + 1
    local myGen = ScrollPollGen
    EnsureScrollKeyTables()

    local function Tick()
        if myGen ~= ScrollPollGen or not IsThirdPerson then
            if myGen == ScrollPollGen then
                ScrollPollActive = false
            end
            return
        end

        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then
            IsThirdPerson = false
            ScrollPollActive = false
            return
        end

        local shipActor = GetPilotedShipActor(pc)
        if not Core.IsValidObj(shipActor) then
            -- Player exited the pilot seat: restore original 1st-person camera and stop polling
            if ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
                RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
            end
            ActiveShipAddr = nil
            IsThirdPerson = false
            ScrollPollActive = false
            return
        end

        if not (Core.IsAnyBlockingMenuOpen and Core.IsAnyBlockingMenuOpen()) then
            local delta = 0.0
            pcall(function()
                if KEY_MOUSE_WHEEL_AXIS and pc.GetInputAnalogKeyState then
                    delta = tonumber(pc:GetInputAnalogKeyState(KEY_MOUSE_WHEEL_AXIS)) or 0.0
                end
                if delta == 0.0 and KEY_SCROLL_UP and KEY_SCROLL_DOWN then
                    if pc:WasInputKeyJustPressed(KEY_SCROLL_UP) then
                        delta = 1.0
                    elseif pc:WasInputKeyJustPressed(KEY_SCROLL_DOWN) then
                        delta = -1.0
                    end
                end
            end)
            if delta > 0.01 then
                ZoomMultiplier = Core.Clamp(ZoomMultiplier - ZOOM_MULT_STEP, MIN_ZOOM_MULT, MAX_ZOOM_MULT)
                ApplyShipCameraState(pc)
            elseif delta < -0.01 then
                ZoomMultiplier = Core.Clamp(ZoomMultiplier + ZOOM_MULT_STEP, MIN_ZOOM_MULT, MAX_ZOOM_MULT)
                ApplyShipCameraState(pc)
            end
        end

        ExecuteInGameThreadAfterFrames(1, Tick)
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

local function ToggleShipPerspective()
    if not Core.IsFeatureEnabled("ShipCamera") then return end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end
    local shipActor = GetPilotedShipActor(pc)
    if not Core.IsValidObj(shipActor) then return end

    IsThirdPerson = not IsThirdPerson
    ApplyShipCameraState(pc)
    if IsThirdPerson then
        StartScrollPoll()
    end
end

local function ResetCameraState()
    if ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
        RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
    end
    IsThirdPerson = false
    ScrollPollActive = false
    ScrollPollGen = ScrollPollGen + 1
    ActiveShipAddr = nil
    SavedOriginalCamera = {}
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "ShipPerspectiveKey",
        DefaultKey  = "H",
        MappingName = "Eqol_ShipPerspective",
        Label       = "Ship Camera Perspective",
        CanTrigger  = IsPilotingShipNow,
        OnPress     = ToggleShipPerspective,
    })
end

function Feature.OnToggle(enabled)
    if not enabled then
        ResetCameraState()
    end
end

function Feature.OnClientRestart()
    ResetCameraState()
end

function Feature.OnMapLoad()
    ResetCameraState()
end

function Feature.PruneCaches()
    for addr, saved in pairs(SavedOriginalCamera) do
        if not saved or not Core.IsValidObj(saved.ShipActor) then
            SavedOriginalCamera[addr] = nil
        end
    end
end

return Feature
