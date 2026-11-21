-- Eqol Feature: Ship 3rd-Person Perspective, Scroll Zoom, Boost Camera & Contextual Ship Keybind Legend
-- Configurable keybind (default H) to toggle 1st/3rd person while piloting a ship,
-- mouse scroll wheel to adjust 3rd-person camera distance, MMB to reset zoom,
-- smooth reactive boost zoom/FOV while holding Spacebar, and contextual bottom-left keybind legend.

local Core = require("core")

local Feature = {
    Name        = "ShipCamera",
    DisplayName = "Ship 3rd-Person Camera & Zoom",
    Description = "Hotkey (default H) for 3rd-person ship perspective with scroll-wheel zoom, MMB reset, and boost camera.",
}

local MIN_ZOOM_MULT = 1.00
local DEFAULT_ZOOM_MULT = 3.00
local MAX_ZOOM_MULT = 7.00
local ZOOM_MULT_STEP = 0.25

local BOOST_EXTRA_ZOOM = 0.18 -- +18% smooth zoom-out while boosting (independent of manual ZoomMultiplier)
local BOOST_EXTRA_FOV  = 12.0 -- +12 deg smooth FOV kick while boosting

local IsThirdPerson = false
local ZoomMultiplier = DEFAULT_ZOOM_MULT
local BoostBlend = 0.0
local ScrollPollActive = false
local PilotLegendPollActive = false
local SavedOriginalCamera = {} -- shipActorAddr -> { ShipActor, ShipObj, SpringArm, TargetArmLength, Cam, RelativeLocation, RelativeRotation, FieldOfView, ShipRadius }
local ActiveShipAddr = nil

-- Hoisted FName key tables (avoids per-frame FName allocation; see learning.md §8)
local KEY_MOUSE_WHEEL_AXIS = nil
local KEY_SCROLL_UP = nil
local KEY_SCROLL_DOWN = nil
local KEY_MMB = nil
local KEY_SPACE = nil

local function EnsureScrollKeyTables()
    if KEY_MOUSE_WHEEL_AXIS == nil then
        pcall(function() KEY_MOUSE_WHEEL_AXIS = { KeyName = FName("MouseWheelAxis") } end)
        pcall(function() KEY_SCROLL_UP = { KeyName = FName("MouseScrollUp") } end)
        pcall(function() KEY_SCROLL_DOWN = { KeyName = FName("MouseScrollDown") } end)
        pcall(function() KEY_MMB = { KeyName = FName("MiddleMouseButton") } end)
        pcall(function() KEY_SPACE = { KeyName = FName("SpaceBar") } end)
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
        FieldOfView = 90.0,
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
            if type(cam.FieldOfView) == "number" and cam.FieldOfView > 10.0 then
                saved.FieldOfView = cam.FieldOfView
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
    if Core.IsValidObj(saved.Cam) and type(saved.FieldOfView) == "number" then
        pcall(function()
            if saved.Cam.SetFieldOfView then
                saved.Cam:SetFieldOfView(saved.FieldOfView)
            else
                saved.Cam.FieldOfView = saved.FieldOfView
            end
        end)
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

local function ApplyShipCameraState(pc, logChange)
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
    if IsThirdPerson and logChange and saved then
        saved.ShipRadius = MeasureShipRadiusCm(shipActor)
    end
    local shipRadius = (saved and saved.ShipRadius) or 1400.0
    local boostFactor = 1.0 + (IsThirdPerson and (BOOST_EXTRA_ZOOM * BoostBlend) or 0.0)
    local effectiveZoom = ZoomMultiplier * boostFactor
    local backDist = shipRadius * 1.65 * effectiveZoom
    local upHeight = shipRadius * 0.48 * effectiveZoom

    if logChange then
        Core.Log(string.format("[ShipCamera] Apply 3P=%s zoom=%.2fx radius=%.0f back=%.0f up=%.0f actor=%s",
            tostring(IsThirdPerson), ZoomMultiplier, shipRadius, backDist, upHeight,
            Core.IsValidObj(shipActor) and shipActor:GetClass():GetFName():ToString() or "nil"))
    end

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

    if Core.IsValidObj(cam) and saved and type(saved.FieldOfView) == "number" then
        pcall(function()
            local targetFov = IsThirdPerson and (saved.FieldOfView + BOOST_EXTRA_FOV * BoostBlend) or saved.FieldOfView
            if cam.SetFieldOfView then
                cam:SetFieldOfView(targetFov)
            else
                cam.FieldOfView = targetFov
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

--------------------------------------------------------------------------------
-- Contextual Bottom-Left Ship Keybind Legend (matching Station Map / World Map style)
--------------------------------------------------------------------------------

local LegendUI = nil -- { Root, PerspRow, PerspKeyTxt, ZeroRow, ZeroKeyTxt, ZoomRow, ResetRow, LastPerspKey, LastZeroKey }
local CachedMMBIconTex = nil
local MMBIconSearched = false

local KEY_DISPLAY_MAP = {
    Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
    Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
    SpaceBar = "SPACE", LeftShift = "SHIFT", RightShift = "SHIFT",
    LeftControl = "CTRL", RightControl = "CTRL", LeftAlt = "ALT", RightAlt = "ALT",
    MiddleMouseButton = "MMB", LeftMouseButton = "LMB", RightMouseButton = "RMB",
}

local function FormatKeyLabel(keyName, fallback)
    local raw = (type(keyName) == "string" and keyName ~= "") and keyName or fallback
    if not raw or raw == "None" then return nil end
    return KEY_DISPLAY_MAP[raw] or string.upper(raw)
end

local function FindMMBIconTexture()
    if Core.IsValidObj(CachedMMBIconTex) then return CachedMMBIconTex end
    if MMBIconSearched then return nil end
    MMBIconSearched = true

    local candidates = {
        "/Game/Materials/Icons/UI/T_UI_MMB.T_UI_MMB",
        "/Game/Materials/Icons/UI/T_UI_MouseMiddle.T_UI_MouseMiddle",
        "/Game/Materials/UI_Textures/T_MMB.T_MMB",
        "/Game/Materials/Icons/T_MMB.T_MMB",
    }
    for _, p in ipairs(candidates) do
        local tex = Core.FindOrLoadClass(p)
        if Core.IsValidObj(tex) then
            CachedMMBIconTex = tex
            return tex
        end
    end

    local okAll, texList = pcall(FindAllOf, "Texture2D")
    if okAll and texList then
        for _, tex in ipairs(texList) do
            if Core.IsValidObj(tex) then
                local okN, fullName = pcall(function() return tex:GetFullName() end)
                if okN and type(fullName) == "string" then
                    local low = fullName:lower()
                    if low:find("mmb", 1, true)
                        or (low:find("mouse", 1, true) and (low:find("middle", 1, true) or low:find("wheel", 1, true)))
                    then
                        CachedMMBIconTex = tex
                        Core.Log("[ShipCamera] Found MMB icon texture: " .. fullName)
                        return tex
                    end
                end
            end
        end
    end
    return nil
end

local function DestroyShipLegend()
    if LegendUI and Core.IsValidObj(LegendUI.Root) then
        pcall(function() LegendUI.Root:RemoveFromParent() end)
    end
    LegendUI = nil
end

local function EnsureShipLegend(pc)
    if LegendUI and Core.IsValidObj(LegendUI.Root) then
        return LegendUI
    end
    if not Core.IsValidObj(pc) then return nil end

    local rootWin = Core.CreateUserWidget("/Script/UMG.UserWidget", pc, pc)
    if not (Core.IsValidObj(rootWin) and Core.IsValidObj(rootWin.WidgetTree)) then
        return nil
    end

    local outer = rootWin.WidgetTree
    local rootOverlay = Core.CreateRawWidget("/Script/UMG.Overlay", outer)
    local vbox = Core.CreateRawWidget("/Script/UMG.VerticalBox", outer)
    if not (Core.IsValidObj(rootOverlay) and Core.IsValidObj(vbox)) then
        return nil
    end

    local capFillCol   = { R = 0.0194, G = 0.0194, B = 0.0194, A = 0.78 } -- #262626 translucent
    local capTextCol   = { R = 0.96,   G = 0.97,   B = 1.00,   A = 1.00 }
    local hintLabelCol = { R = 0.86,   G = 0.88,   B = 0.92,   A = 0.96 }
    local wbpTextPath  = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C"

    local function applyBadgeStyle(bdr, padTbl)
        pcall(function()
            bdr:SetBrushColor(capFillCol)
            bdr:SetPadding(padTbl)
            bdr:SetVisibility(3)
            local bg = bdr.Background
            if bg then
                bg.DrawAs = 4 -- RoundedBox
                if bg.OutlineSettings then
                    bg.OutlineSettings.CornerRadii = { X = 3.0, Y = 3.0, Z = 3.0, W = 3.0 }
                    bg.OutlineSettings.RoundingType = 0 -- FixedRadius
                    bg.OutlineSettings.Width = 0.0
                    bg.OutlineSettings.bUseBrushTransparency = true
                end
                bdr:SetBrush(bg)
            end
        end)
    end

    local function makeRow(idx, keyText, iconTex, labelText)
        local row = Core.CreateRawWidget("/Script/UMG.HorizontalBox", outer)
        if not Core.IsValidObj(row) then return nil, nil end
        pcall(function() row:SetVisibility(1) end) -- Start Collapsed

        local capBg = Core.CreateRawWidget("/Script/UMG.Border", outer)
        local keyTxtWidget = nil
        if Core.IsValidObj(capBg) then
            local builtIcon = false
            if Core.IsValidObj(iconTex) then
                local sb = Core.CreateRawWidget("/Script/UMG.SizeBox", outer)
                local img = Core.CreateRawWidget("/Script/UMG.Image", outer)
                if Core.IsValidObj(sb) and Core.IsValidObj(img) then
                    applyBadgeStyle(capBg, { Left = 4.0, Top = 3.0, Right = 4.0, Bottom = 3.0 })
                    pcall(function()
                        sb:SetWidthOverride(18.0)
                        sb:SetHeightOverride(18.0)
                        sb:SetVisibility(3)
                        img:SetBrushFromTexture(iconTex, false)
                        img:SetVisibility(3)
                        sb:AddChild(img)
                        capBg:AddChild(sb)
                    end)
                    builtIcon = true
                end
            end
            if not builtIcon then
                local kt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
                if Core.IsValidObj(kt) then
                    applyBadgeStyle(capBg, { Left = 7.0, Top = 2.0, Right = 7.0, Bottom = 2.0 })
                    pcall(function()
                        kt:SetVisibility(3)
                        kt:SetSize(10)
                        kt:SetText(Core.MakeText(keyText or ""))
                        if kt.SetColorAndOpacity then kt:SetColorAndOpacity(capTextCol) end
                        capBg:AddChild(kt)
                    end)
                    keyTxtWidget = kt
                end
            end
            local kSlot = row:AddChildToHorizontalBox(capBg)
            if Core.IsValidObj(kSlot) then pcall(function() kSlot:SetVerticalAlignment(2) end) end
        end

        local lbl = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
        if Core.IsValidObj(lbl) then
            pcall(function()
                lbl:SetVisibility(3)
                lbl:SetSize(11)
                lbl:SetText(Core.MakeText(labelText))
                if lbl.SetColorAndOpacity then lbl:SetColorAndOpacity(hintLabelCol) end
            end)
            local lSlot = row:AddChildToHorizontalBox(lbl)
            if Core.IsValidObj(lSlot) then
                pcall(function()
                    lSlot:SetVerticalAlignment(2)
                    lSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end)
            end
        end

        local rSlot = vbox:AddChildToVerticalBox(row)
        if Core.IsValidObj(rSlot) then
            pcall(function()
                rSlot:SetHorizontalAlignment(1)
                rSlot:SetPadding({ Left = 0.0, Top = (idx == 1) and 0.0 or 5.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
        return row, keyTxtWidget
    end

    pcall(function()
        rootOverlay:SetVisibility(4) -- SelfHitTestInvisible
        vbox:SetVisibility(4)
    end)

    local mmbTex = FindMMBIconTexture()
    local perspRow, perspKeyTxt = makeRow(1, FormatKeyLabel(Core.Config.ShipPerspectiveKey, "H") or "H", nil, "3rd-Person Camera")
    local zeroRow, zeroKeyTxt   = makeRow(2, FormatKeyLabel(Core.Config.ShipZeroThrottleKey, "Zero") or "0", nil, "Zero Throttle")
    local zoomRow               = makeRow(3, "SCROLL", nil, "Zoom Camera")
    local resetRow              = makeRow(4, "MMB", mmbTex, "Reset Zoom")

    local blSlot = rootOverlay:AddChildToOverlay(vbox)
    if Core.IsValidObj(blSlot) then
        pcall(function()
            blSlot:SetHorizontalAlignment(1) -- Left
            blSlot:SetVerticalAlignment(3)   -- Bottom
            blSlot:SetPadding({ Left = 10.0, Top = 0.0, Right = 0.0, Bottom = 14.0 })
        end)
    end

    pcall(function()
        rootWin.WidgetTree.RootWidget = rootOverlay
        rootWin:SetVisibility(1) -- Collapsed until piloting
        rootWin:AddToViewport(20)
        rootWin:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
    end)

    LegendUI = {
        Root = rootWin,
        PerspRow = perspRow,
        PerspKeyTxt = perspKeyTxt,
        ZeroRow = zeroRow,
        ZeroKeyTxt = zeroKeyTxt,
        ZoomRow = zoomRow,
        ResetRow = resetRow,
        LastPerspKey = nil,
        LastZeroKey = nil,
    }
    return LegendUI
end

local function UpdateShipLegend()
    local pc = Core.GetLocalPlayerController()
    local piloting = IsPilotingShipNow()

    local perspKeyStr = Core.IsFeatureEnabled("ShipCamera") and FormatKeyLabel(Core.Config.ShipPerspectiveKey, "H") or nil
    local zeroKeyStr  = Core.IsFeatureEnabled("ShipZeroThrottle") and FormatKeyLabel(Core.Config.ShipZeroThrottleKey, "Zero") or nil
    local showPersp = piloting and (perspKeyStr ~= nil)
    local showZero  = piloting and (zeroKeyStr ~= nil)
    local showZoom  = piloting and IsThirdPerson and Core.IsFeatureEnabled("ShipCamera")
    local showAny   = showPersp or showZero or showZoom

    if not showAny then
        if LegendUI and Core.IsValidObj(LegendUI.Root) then
            pcall(function() LegendUI.Root:SetVisibility(1) end)
        end
        return
    end

    local ui = EnsureShipLegend(pc)
    if not ui or not Core.IsValidObj(ui.Root) then return end

    pcall(function()
        if ui.Root.IsInViewport and not ui.Root:IsInViewport() then
            ui.Root:AddToViewport(20)
        end
        if showPersp and ui.LastPerspKey ~= perspKeyStr and Core.IsValidObj(ui.PerspKeyTxt) then
            ui.LastPerspKey = perspKeyStr
            ui.PerspKeyTxt:SetText(Core.MakeText(perspKeyStr))
        end
        if showZero and ui.LastZeroKey ~= zeroKeyStr and Core.IsValidObj(ui.ZeroKeyTxt) then
            ui.LastZeroKey = zeroKeyStr
            ui.ZeroKeyTxt:SetText(Core.MakeText(zeroKeyStr))
        end
        if Core.IsValidObj(ui.PerspRow) then ui.PerspRow:SetVisibility(showPersp and 3 or 1) end
        if Core.IsValidObj(ui.ZeroRow)  then ui.ZeroRow:SetVisibility(showZero and 3 or 1) end
        if Core.IsValidObj(ui.ZoomRow)  then ui.ZoomRow:SetVisibility(showZoom and 3 or 1) end
        if Core.IsValidObj(ui.ResetRow) then ui.ResetRow:SetVisibility(showZoom and 3 or 1) end
        ui.Root:SetVisibility(4) -- SelfHitTestInvisible
    end)
end

local function StartPilotLegendPoll()
    if PilotLegendPollActive then return end
    PilotLegendPollActive = true
    local function Tick()
        pcall(UpdateShipLegend)
        ExecuteInGameThreadWithDelay(250, Tick)
    end
    ExecuteInGameThreadWithDelay(500, Tick)
end

local ScrollPollGen = 0

-- On-demand frame-synchronized scroll/MMB/boost loop: runs ONLY while IsThirdPerson is active (learning.md §8)
local function StartScrollPoll()
    if ScrollPollActive then return end
    ScrollPollActive = true
    ScrollPollGen = ScrollPollGen + 1
    local myGen = ScrollPollGen
    local lastClock = os.clock()
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
            BoostBlend = 0.0
            ScrollPollActive = false
            UpdateShipLegend()
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
            BoostBlend = 0.0
            ScrollPollActive = false
            UpdateShipLegend()
            return
        end

        local now = os.clock()
        local dt = math.max(0.001, math.min(0.05, now - lastClock))
        lastClock = now

        local blocking = (Core.IsAnyBlockingMenuOpen and Core.IsAnyBlockingMenuOpen()) == true
        local needsApply = false

        if not blocking then
            -- 1. Scroll-wheel manual zoom
            local delta = 0.0
            local mmbPressed = false
            local boostHeld = false
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
                if KEY_MMB and pc.WasInputKeyJustPressed then
                    mmbPressed = (pc:WasInputKeyJustPressed(KEY_MMB) == true)
                end
                if KEY_SPACE and pc.IsInputKeyDown then
                    boostHeld = (pc:IsInputKeyDown(KEY_SPACE) == true)
                end
            end)

            if mmbPressed and math.abs(ZoomMultiplier - DEFAULT_ZOOM_MULT) > 0.001 then
                ZoomMultiplier = DEFAULT_ZOOM_MULT
                needsApply = true
            elseif delta > 0.01 then
                local nextZ = Core.Clamp(ZoomMultiplier - ZOOM_MULT_STEP, MIN_ZOOM_MULT, MAX_ZOOM_MULT)
                if math.abs(nextZ - ZoomMultiplier) > 0.0001 then
                    ZoomMultiplier = nextZ
                    needsApply = true
                end
            elseif delta < -0.01 then
                local nextZ = Core.Clamp(ZoomMultiplier + ZOOM_MULT_STEP, MIN_ZOOM_MULT, MAX_ZOOM_MULT)
                if math.abs(nextZ - ZoomMultiplier) > 0.0001 then
                    ZoomMultiplier = nextZ
                    needsApply = true
                end
            end

            -- 2. Smooth reactive boost camera (independent BoostBlend 0..1)
            local targetBlend = boostHeld and 1.0 or 0.0
            if math.abs(BoostBlend - targetBlend) > 0.001 then
                local rate = boostHeld and 7.5 or 4.5
                local alpha = 1.0 - math.exp(-rate * dt)
                BoostBlend = BoostBlend + (targetBlend - BoostBlend) * alpha
                if math.abs(BoostBlend - targetBlend) < 0.002 then
                    BoostBlend = targetBlend
                end
                needsApply = true
            end
        elseif BoostBlend > 0.001 then
            BoostBlend = math.max(0.0, BoostBlend - dt * 5.0)
            needsApply = true
        end

        if needsApply then
            ApplyShipCameraState(pc, false)
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
    if not IsThirdPerson then
        BoostBlend = 0.0
    end
    ApplyShipCameraState(pc, true)
    UpdateShipLegend()
    if IsThirdPerson then
        StartScrollPoll()
    end
end

local function ResetCameraState()
    if ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
        RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
    end
    IsThirdPerson = false
    BoostBlend = 0.0
    ScrollPollActive = false
    ScrollPollGen = ScrollPollGen + 1
    ActiveShipAddr = nil
    SavedOriginalCamera = {}
    DestroyShipLegend()
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "ShipPerspectiveKey",
        DefaultKey  = "H",
        MappingName = "Eqol_ShipPerspective",
        Label       = "Ship Camera Perspective",
        CanTrigger  = IsPilotingShipNow,
        OnPress     = ToggleShipPerspective,
        OnChanged   = UpdateShipLegend,
    })
    StartPilotLegendPoll()
end

function Feature.OnToggle(enabled)
    if not enabled then
        if ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
            RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
        end
        IsThirdPerson = false
        BoostBlend = 0.0
        ScrollPollActive = false
        ScrollPollGen = ScrollPollGen + 1
    end
    UpdateShipLegend()
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
