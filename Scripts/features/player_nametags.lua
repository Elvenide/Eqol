-- Eqol Feature: Player Nametags with Online/Offline Status
-- Displays 3D Minecraft-style world-space nametags above players (relative to the viewing camera),
-- with a translucent black background, camera-facing rotation, and max viewing distance.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "PlayerNametags",
}

local PATHS = {
    WBPTextClass    = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    ActorClass      = "/Script/Engine.Actor",
    WidgetCompClass = "/Script/UMG.WidgetComponent",
}

local COLORS = {
    Bg      = { R = 0.0, G = 0.0, B = 0.0, A = 0.55 },
    Online  = { R = 0.35, G = 0.95, B = 0.35, A = 1.0 },
    Offline = { R = 0.90, G = 0.35, B = 0.35, A = 1.0 },
}

local HEAD_OFFSET   = 215.0  -- cm above actor origin along player's local up vector (clears helmet)
local MAX_VIEW_DIST = 2500.0 -- 25 meters max viewing distance from camera
local MIN_CAM_DIST  = 120.0  -- hide when camera is inside player's head (1st-person)
local TAG_SCALE     = 0.25   -- 3D world scale for crisp Minecraft-style proportions

local TagPool = {} -- idx -> { Actor, Comp, TextWidget }
local PollActive = false

local function DestroyTagPool()
    for i, entry in ipairs(TagPool) do
        if entry and Core.IsValidObj(entry.Actor) then
            pcall(function() entry.Actor:K2_DestroyActor() end)
        end
        TagPool[i] = nil
    end
end

local function GetOrCreateTagActor(pc, idx)
    local entry = TagPool[idx]
    if entry and Core.IsValidObj(entry.Actor) and Core.IsValidObj(entry.Comp) and Core.IsValidObj(entry.TextWidget) then
        return entry
    end

    local compCls = Core.FindOrLoadClass(PATHS.WidgetCompClass)
    if not Core.IsValidObj(compCls) then return nil end

    local actor = Core.SpawnActor(pc, PATHS.ActorClass, { X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    if not Core.IsValidObj(actor) then return nil end

    local xform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local okC, comp = pcall(function()
        return actor:AddComponentByClass(compCls, false, xform, false)
    end)
    if not okC or not Core.IsValidObj(comp) then
        pcall(function() actor:K2_DestroyActor() end)
        return nil
    end

    pcall(function() actor:K2_SetRootComponent(comp) end)

    local nameTxt = Core.CreateUserWidget(PATHS.WBPTextClass, pc, pc)
    if not Core.IsValidObj(nameTxt) then
        pcall(function() actor:K2_DestroyActor() end)
        return nil
    end

    pcall(function()
        nameTxt:SetSize(16)
        nameTxt:SetJustification(1)
        comp:SetWidgetSpace(0) -- World space
        comp:SetDrawAtDesiredSize(true)
        comp:SetPivot({ X = 0.5, Y = 1.0 })
        comp:SetTwoSided(true)
        comp:SetBackgroundColor(COLORS.Bg)
        comp:SetWidget(nameTxt)
        comp:SetWorldScale3D({ X = TAG_SCALE, Y = TAG_SCALE, Z = TAG_SCALE })
        comp:SetVisibility(false, false)
    end)

    entry = {
        Actor = actor,
        Comp = comp,
        TextWidget = nameTxt,
    }
    TagPool[idx] = entry
    return entry
end

local function UpdateNametags()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local camMgr = pc.PlayerCameraManager
    local mathLib = Core.GetCDO("/Script/Engine.Default__KismetMathLibrary")
    if not (Core.IsValidObj(camMgr) and Core.IsValidObj(mathLib)) then return end

    local okCam, camLoc = pcall(function() return camMgr:GetCameraLocation() end)
    if not okCam or not camLoc then return end

    local players = StationData.GetAllPlayersInfo(pc)
    local count = 0

    for _, p in ipairs(players) do
        if p.HasPos and Core.IsValidObj(p.Actor) and not Core.IsValidObj(p.PilotedShip) then
            -- Use the player's local up vector so nametags always sit above their head in any 3D station orientation
            local up = { X = 0.0, Y = 0.0, Z = 1.0 }
            pcall(function()
                local u = p.Actor:GetActorUpVector()
                if u and u.X then up = { X = u.X, Y = u.Y, Z = u.Z } end
            end)

            local tagPos = {
                X = p.X + up.X * HEAD_OFFSET,
                Y = p.Y + up.Y * HEAD_OFFSET,
                Z = p.Z + up.Z * HEAD_OFFSET,
            }

            local dx = camLoc.X - tagPos.X
            local dy = camLoc.Y - tagPos.Y
            local dz = camLoc.Z - tagPos.Z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

            if dist >= MIN_CAM_DIST and dist <= MAX_VIEW_DIST then
                count = count + 1
                local tag = GetOrCreateTagActor(pc, count)
                if tag then
                    local statusStr = p.IsOnline and "Online" or "Offline"
                    local txtCol = p.IsOnline and COLORS.Online or COLORS.Offline
                    pcall(function()
                        tag.TextWidget:SetText(Core.MakeText(string.format(" %s (%s) ", p.Name, statusStr)))
                        if Core.IsValidObj(tag.TextWidget.TextBlock) then
                            tag.TextWidget.TextBlock:SetColorAndOpacity({ SpecifiedColor = txtCol, ColorUseRule = 0 })
                        end

                        -- Face the viewing camera cleanly while staying upright relative to the player's local Up
                        local toCam = { X = dx, Y = dy, Z = dz }
                        local faceRot = mathLib:MakeRotFromXZ(toCam, up)
                        tag.Comp:K2_SetWorldLocationAndRotation(tagPos, faceRot, false, {}, true)
                        tag.Comp:SetVisibility(true, false)
                    end)
                end
            end
        end
    end

    for i = count + 1, #TagPool do
        local entry = TagPool[i]
        if entry and Core.IsValidObj(entry.Comp) then
            pcall(function() entry.Comp:SetVisibility(false, false) end)
        end
    end
end

local function StartPoll()
    if PollActive then return end
    PollActive = true

    local function Tick()
        pcall(UpdateNametags)
        ExecuteInGameThreadWithDelay(16, Tick)
    end
    ExecuteInGameThreadWithDelay(16, Tick)
end

function Feature.Init()
    StartPoll()
end

function Feature.OnClientRestart()
    DestroyTagPool()
end

return Feature
