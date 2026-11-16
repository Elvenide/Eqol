-- Eqol Feature: Cinematic Freecam Toggle
-- Configurable keybind (default C) that toggles a free-flying camera and hides the HUD simultaneously.

local Core = require("core")

local Feature = {
    Name = "CinematicFreecam",
}

local FreecamActive = false
local FreecamActor = nil
local PrevViewTarget = nil
local ControlledPawn = nil
local PrevOwnerNoSee = nil
local TickRunning = false
local TrackedHuds = {} -- addr -> hud
local BaseCamRot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
local PrevCtrlRot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
local YawOffset = 0.0
local PitchOffset = 0.0
local LoggedBuiltInSpectator = false

local BASE_SPEED = 900.0   -- units/sec (~9 m/s)
local FAST_MULT  = 3.0
local SLOW_MULT  = 0.25

local function NormalizeAngle(deg)
    local a = (deg or 0.0) % 360.0
    if a > 180.0 then a = a - 360.0 end
    return a
end

local function IsDown(pc, keyName)
    local ok, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(keyName) }) end)
    return ok and down == true
end

local function SetHudHiddenState(pc, hidden)
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) then
        pcall(function()
            if hidden then
                widgetSub:HideHUD()
            else
                widgetSub:ShowHUD()
            end
        end)
    end

    for addr, hud in pairs(TrackedHuds) do
        if Core.IsValidObj(hud) then
            pcall(function() hud:SetHUDHidden(hidden) end)
        else
            TrackedHuds[addr] = nil
        end
    end
end

local function SpawnFreecamActor(pc)
    local camMgr = pc.PlayerCameraManager
    local camLoc = { X = 0.0, Y = 0.0, Z = 0.0 }
    local camRot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    if Core.IsValidObj(camMgr) then
        pcall(function()
            local l = camMgr:GetCameraLocation()
            if l then camLoc = { X = l.X or 0, Y = l.Y or 0, Z = l.Z or 0 } end
            local r = camMgr:GetCameraRotation()
            if r then camRot = { Pitch = r.Pitch or 0, Yaw = r.Yaw or 0, Roll = r.Roll or 0 } end
        end)
    end

    local actor = Core.SpawnActor(pc, "/Script/Engine.CameraActor", camLoc, camRot)
    if Core.IsValidObj(actor) then
        BaseCamRot = { Pitch = camRot.Pitch, Yaw = camRot.Yaw, Roll = camRot.Roll }
        YawOffset = 0.0
        PitchOffset = 0.0
        pcall(function()
            local c = pc:GetControlRotation()
            if c then PrevCtrlRot = { Pitch = c.Pitch or 0, Yaw = c.Yaw or 0, Roll = c.Roll or 0 } end
        end)
        pcall(function() actor:K2_SetActorLocationAndRotation(camLoc, camRot, false, {}, true) end)
    end
    return actor
end

local function StartFreecamTick()
    if TickRunning then return end
    TickRunning = true
    local lastClock = os.clock()

    local function Tick()
        if not FreecamActive or not Core.IsValidObj(FreecamActor) then
            TickRunning = false
            return
        end

        local now = os.clock()
        local dt = math.min(math.max(now - lastClock, 0.001), 0.1)
        lastClock = now

        local pc = Core.GetLocalPlayerController()
        local mathLib = Core.GetCDO("/Script/Engine.Default__KismetMathLibrary")
        if Core.IsValidObj(pc) and Core.IsValidObj(mathLib) then
            pcall(function()
                local curCtrl = pc:GetControlRotation()
                local dYaw = NormalizeAngle((curCtrl.Yaw or 0.0) - PrevCtrlRot.Yaw)
                local dPitch = NormalizeAngle((curCtrl.Pitch or 0.0) - PrevCtrlRot.Pitch)
                PrevCtrlRot = { Pitch = curCtrl.Pitch or 0.0, Yaw = curCtrl.Yaw or 0.0, Roll = curCtrl.Roll or 0.0 }

                YawOffset = YawOffset + dYaw
                PitchOffset = math.max(-89.0, math.min(89.0, PitchOffset + dPitch))

                local rot = mathLib:ComposeRotators({ Pitch = PitchOffset, Yaw = YawOffset, Roll = 0.0 }, BaseCamRot)
                FreecamActor:K2_SetActorRotation(rot, false)

                local fwd = mathLib:GetForwardVector(rot)
                local right = mathLib:GetRightVector(rot)
                local up = mathLib:GetUpVector(rot)

                local moveF = (IsDown(pc, "W") and 1 or 0) - (IsDown(pc, "S") and 1 or 0)
                local moveR = (IsDown(pc, "D") and 1 or 0) - (IsDown(pc, "A") and 1 or 0)
                local moveU = ((IsDown(pc, "SpaceBar") or IsDown(pc, "E")) and 1 or 0)
                            - ((IsDown(pc, "LeftControl") or IsDown(pc, "Q")) and 1 or 0)

                if moveF ~= 0 or moveR ~= 0 or moveU ~= 0 then
                    local speed = BASE_SPEED
                    if IsDown(pc, "LeftShift") then speed = speed * FAST_MULT end
                    if IsDown(pc, "LeftAlt") then speed = speed * SLOW_MULT end

                    local curLoc = FreecamActor:K2_GetActorLocation()
                    local step = speed * dt
                    local newLoc = {
                        X = curLoc.X + (fwd.X * moveF + right.X * moveR + up.X * moveU) * step,
                        Y = curLoc.Y + (fwd.Y * moveF + right.Y * moveR + up.Y * moveU) * step,
                        Z = curLoc.Z + (fwd.Z * moveF + right.Z * moveR + up.Z * moveU) * step,
                    }
                    FreecamActor:K2_SetActorLocation(newLoc, false, {}, true)
                end
            end)
        end

        ExecuteInGameThreadWithDelay(16, Tick)
    end

    ExecuteInGameThreadWithDelay(16, Tick)
end

local function DisableFreecam(pc)
    FreecamActive = false
    if Core.IsValidObj(ControlledPawn) and Core.IsValidObj(pc) then
        pcall(function() ControlledPawn:EnableInput(pc) end)
        if PrevOwnerNoSee ~= nil and Core.IsValidObj(ControlledPawn.Mesh) then
            pcall(function() ControlledPawn.Mesh:SetOwnerNoSee(PrevOwnerNoSee) end)
        end
    end
    ControlledPawn = nil
    PrevOwnerNoSee = nil

    if Core.IsValidObj(pc) then
        local target = Core.IsValidObj(PrevViewTarget) and PrevViewTarget or pc.Pawn
        if Core.IsValidObj(target) then
            pcall(function() pc:SetViewTargetWithBlend(target, 0.0, 0, 0.0, false) end)
        end
        pcall(function() pc:SetIgnoreMoveInput(false) end)
        SetHudHiddenState(pc, false)
    end
    if Core.IsValidObj(FreecamActor) then
        pcall(function() FreecamActor:K2_DestroyActor() end)
    end
    FreecamActor = nil
    PrevViewTarget = nil
end

local function LogBuiltInSpectatorHints(pc)
    if LoggedBuiltInSpectator or not Core.IsValidObj(pc) then return end
    LoggedBuiltInSpectator = true
    pcall(function()
        local cls = pc:GetClass()
        if Core.IsValidObj(cls) and cls.ForEachFunction then
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if string.find(n, "Spectat", 1, true) or string.find(n, "Freecam", 1, true) or string.find(n, "HUD", 1, true) then
                    Core.Log("Freecam Reflection [PC fn]: " .. n)
                end
            end)
        end
    end)
end

local function ToggleCinematicFreecam()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    LogBuiltInSpectatorHints(pc)

    if FreecamActive then
        DisableFreecam(pc)
        Core.Log("Cinematic Freecam: OFF")
        return
    end

    pcall(function() PrevViewTarget = pc:GetViewTarget() end)
    FreecamActor = SpawnFreecamActor(pc)
    if not Core.IsValidObj(FreecamActor) then
        Core.Log("Cinematic Freecam: failed to spawn CameraActor")
        return
    end

    FreecamActive = true
    ControlledPawn = pc.Pawn
    if Core.IsValidObj(ControlledPawn) then
        pcall(function() ControlledPawn:DisableInput(pc) end)
        if Core.IsValidObj(ControlledPawn.Mesh) then
            pcall(function()
                PrevOwnerNoSee = ControlledPawn.Mesh.bOwnerNoSee
                ControlledPawn.Mesh:SetOwnerNoSee(false)
            end)
        end
    end
    pcall(function() pc:SetViewTargetWithBlend(FreecamActor, 0.0, 0, 0.0, false) end)
    pcall(function() pc:SetIgnoreMoveInput(true) end)
    SetHudHiddenState(pc, true)
    StartFreecamTick()
    Core.Log("Cinematic Freecam: ON")
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        if Core.IsValidObj(hud) then
            TrackedHuds[hud:GetAddress()] = hud
        end
    end,
    WBP_ShipHUD_C = function(hud)
        if Core.IsValidObj(hud) then
            TrackedHuds[hud:GetAddress()] = hud
        end
    end,
}

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "CinematicFreecamKey",
        DefaultKey  = "C",
        MappingName = "Eqol_CinematicFreecam",
        Label       = "Cinematic Freecam",
        OnPress     = ToggleCinematicFreecam,
    })
end

function Feature.OnClientRestart()
    DisableFreecam(Core.GetLocalPlayerController())
end

function Feature.PruneCaches()
    for addr, hud in pairs(TrackedHuds) do
        if not Core.IsValidObj(hud) then
            TrackedHuds[addr] = nil
        end
    end
end

return Feature
