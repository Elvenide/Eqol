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

local LegendUI = nil -- { Root, PerspRow, PerspKeyTxt, ZeroRow, ZeroKeyTxt, ZoomRow, ResetRow, LeftWing, RightWing, ... }
local TelemetryDiagLogged = false
local CachedMMBIconTex = nil
local MMBIconSearched = false

local TELEM_RED    = { R = 0.6105, G = 0.0000, B = 0.0612, A = 1.00 } -- #cd0046 (matches Station Map missing materials)
local TELEM_ORANGE = { R = 0.9200, G = 0.4500, B = 0.0400, A = 0.96 }
local TELEM_GREEN  = { R = 0.1400, G = 0.7200, B = 0.2400, A = 0.96 }
local TELEM_GOLD   = { R = 0.9400, G = 0.6600, B = 0.1000, A = 1.00 }
local TELEM_BOOST  = { R = 0.2000, G = 0.8400, B = 1.0000, A = 1.00 }
local TELEM_DIM    = { R = 0.2600, G = 0.2800, B = 0.3200, A = 0.85 }
local TELEM_EMPTY  = { R = 0.0300, G = 0.0350, B = 0.0450, A = 0.78 }
local TELEM_PANEL  = { R = 0.0150, G = 0.0180, B = 0.0240, A = 0.74 }
local TELEM_WHITE  = { R = 0.9400, G = 0.9500, B = 0.9800, A = 1.00 }
local TELEM_MUTED  = { R = 0.6800, G = 0.7200, B = 0.7800, A = 0.90 }

local BOOST_BAR_H = 160.0

local function SetWBPTextCol(w, col)
    if not Core.IsValidObj(w) or not col then return end
    pcall(function()
        if w.SetColorAndOpacity then w:SetColorAndOpacity(col) end
        if Core.IsValidObj(w.TextBlock) and w.TextBlock.SetColorAndOpacity then
            w.TextBlock:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
        end
    end)
end

local function FormatEnergyValue(val, isRate)
    if type(val) ~= "number" then return "--" end
    local absV = math.abs(val)
    local suffix = isRate and "/s" or ""
    if absV >= 1000.0 then
        return string.format("%.1f GJ%s", val / 1000.0, suffix)
    elseif absV >= 1.0 then
        return string.format("%.1f MJ%s", val, suffix)
    else
        return string.format("%.0f kJ%s", val * 1000.0, suffix)
    end
end

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

    -- Helper for tiny gold hairline accent bars
    local function makeHairline(col, hPx)
        local sb = Core.CreateRawWidget("/Script/UMG.SizeBox", outer)
        local bdr = Core.CreateRawWidget("/Script/UMG.Border", outer)
        if Core.IsValidObj(sb) and Core.IsValidObj(bdr) then
            pcall(function()
                sb:SetHeightOverride(hPx or 2.0)
                sb:SetVisibility(3)
                bdr:SetBrushColor(col)
                bdr:SetVisibility(3)
                sb:AddChild(bdr)
            end)
        end
        return sb
    end

    -- Left-Center 3rd-Person Telemetry Wing (seamlessly connected right next to the left-center HUD bracket)
    local leftWing = Core.CreateRawWidget("/Script/UMG.HorizontalBox", outer)
    local boostFillSlot = nil
    local boostFillBorder = nil
    local boostLabelTxt = nil
    local speedTxt = nil
    local fuelUseTxt = nil
    local fuelAvailTxt = nil

    if Core.IsValidObj(leftWing) then
        pcall(function() leftWing:SetVisibility(1) end) -- Collapsed until 3rd-person active

        -- Vertical smooth boost progress bar
        local boostColVBox = Core.CreateRawWidget("/Script/UMG.VerticalBox", outer)
        local boostTrackSb = Core.CreateRawWidget("/Script/UMG.SizeBox", outer)
        local boostTrackBg = Core.CreateRawWidget("/Script/UMG.Border", outer)
        local boostCanvas = Core.CreateRawWidget("/Script/UMG.CanvasPanel", outer)
        boostFillBorder = Core.CreateRawWidget("/Script/UMG.Border", outer)

        if Core.IsValidObj(boostColVBox) and Core.IsValidObj(boostTrackSb) and Core.IsValidObj(boostTrackBg)
            and Core.IsValidObj(boostCanvas) and Core.IsValidObj(boostFillBorder)
        then
            pcall(function()
                boostColVBox:SetVisibility(3)
                boostTrackSb:SetWidthOverride(10.0)
                boostTrackSb:SetHeightOverride(BOOST_BAR_H)
                boostTrackSb:SetVisibility(3)
                boostTrackBg:SetBrushColor(TELEM_EMPTY)
                boostTrackBg:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                boostTrackBg:SetVisibility(3)
                boostCanvas:SetVisibility(3)
                boostFillBorder:SetBrushColor(TELEM_GOLD)
                boostFillBorder:SetVisibility(3)

                boostFillSlot = boostCanvas:AddChildToCanvas(boostFillBorder)
                if Core.IsValidObj(boostFillSlot) then
                    boostFillSlot:SetAnchors({ Minimum = { X = 0.0, Y = 1.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                    boostFillSlot:SetAlignment({ X = 0.0, Y = 1.0 })
                    boostFillSlot:SetPosition({ X = 0.0, Y = 0.0 })
                    boostFillSlot:SetSize({ X = 0.0, Y = BOOST_BAR_H })
                end
                boostTrackBg:AddChild(boostCanvas)
                boostTrackSb:AddChild(boostTrackBg)
                local btSlot = boostColVBox:AddChildToVerticalBox(boostTrackSb)
                if Core.IsValidObj(btSlot) then btSlot:SetHorizontalAlignment(2) end
            end)

            boostLabelTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(boostLabelTxt) then
                pcall(function()
                    boostLabelTxt:SetVisibility(3)
                    boostLabelTxt:SetSize(8)
                    boostLabelTxt:SetText(Core.MakeText("BOOST"))
                end)
                SetWBPTextCol(boostLabelTxt, TELEM_MUTED)
                local blbSlot = boostColVBox:AddChildToVerticalBox(boostLabelTxt)
                if Core.IsValidObj(blbSlot) then
                    pcall(function()
                        blbSlot:SetHorizontalAlignment(2)
                        blbSlot:SetPadding({ Left = 0.0, Top = 4.0, Right = 0.0, Bottom = 0.0 })
                    end)
                end
            end

            local bColSlot = leftWing:AddChildToHorizontalBox(boostColVBox)
            if Core.IsValidObj(bColSlot) then pcall(function() bColSlot:SetVerticalAlignment(2) end) end
        end

        -- Speed, movement direction & fuel panel right next to boost bar
        local infoPanel = Core.CreateRawWidget("/Script/UMG.Border", outer)
        local infoOuterV = Core.CreateRawWidget("/Script/UMG.VerticalBox", outer)
        local infoInnerV = Core.CreateRawWidget("/Script/UMG.VerticalBox", outer)
        if Core.IsValidObj(infoPanel) and Core.IsValidObj(infoOuterV) and Core.IsValidObj(infoInnerV) then
            pcall(function()
                infoPanel:SetBrushColor(TELEM_PANEL)
                infoPanel:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                infoPanel:SetVisibility(3)
                infoOuterV:SetVisibility(3)
                infoInnerV:SetVisibility(3)
            end)

            local topLine = makeHairline(TELEM_GOLD, 2.0)
            if Core.IsValidObj(topLine) then
                local tlS = infoOuterV:AddChildToVerticalBox(topLine)
                if Core.IsValidObj(tlS) then pcall(function() tlS:SetHorizontalAlignment(0) end) end
            end

            speedTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(speedTxt) then
                pcall(function()
                    speedTxt:SetVisibility(3)
                    speedTxt:SetSize(14)
                    speedTxt:SetText(Core.MakeText("0 m/s"))
                end)
                SetWBPTextCol(speedTxt, TELEM_GOLD)
                local spS = infoInnerV:AddChildToVerticalBox(speedTxt)
                if Core.IsValidObj(spS) then
                    pcall(function()
                        spS:SetHorizontalAlignment(1)
                        spS:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 6.0 })
                    end)
                end
            end

            fuelUseTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(fuelUseTxt) then
                pcall(function()
                    fuelUseTxt:SetVisibility(3)
                    fuelUseTxt:SetSize(11)
                    fuelUseTxt:SetText(Core.MakeText("Using: --"))
                end)
                SetWBPTextCol(fuelUseTxt, TELEM_GOLD)
                local fuS = infoInnerV:AddChildToVerticalBox(fuelUseTxt)
                if Core.IsValidObj(fuS) then
                    pcall(function()
                        fuS:SetHorizontalAlignment(1)
                        fuS:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 3.0 })
                    end)
                end
            end

            fuelAvailTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(fuelAvailTxt) then
                pcall(function()
                    fuelAvailTxt:SetVisibility(3)
                    fuelAvailTxt:SetSize(11)
                    fuelAvailTxt:SetText(Core.MakeText("Fuel: --"))
                end)
                SetWBPTextCol(fuelAvailTxt, TELEM_GOLD)
                local faS = infoInnerV:AddChildToVerticalBox(fuelAvailTxt)
                if Core.IsValidObj(faS) then pcall(function() faS:SetHorizontalAlignment(1) end) end
            end

            local inS = infoOuterV:AddChildToVerticalBox(infoInnerV)
            if Core.IsValidObj(inS) then
                pcall(function()
                    inS:SetPadding({ Left = 10.0, Top = 8.0, Right = 12.0, Bottom = 8.0 })
                    inS:SetHorizontalAlignment(1)
                end)
            end

            local botLine = makeHairline({ R = 0.94, G = 0.66, B = 0.10, A = 0.55 }, 1.5)
            if Core.IsValidObj(botLine) then
                local blS = infoOuterV:AddChildToVerticalBox(botLine)
                if Core.IsValidObj(blS) then pcall(function() blS:SetHorizontalAlignment(0) end) end
            end

            pcall(function() infoPanel:AddChild(infoOuterV) end)
            local ipSlot = leftWing:AddChildToHorizontalBox(infoPanel)
            if Core.IsValidObj(ipSlot) then
                pcall(function()
                    ipSlot:SetVerticalAlignment(2)
                    ipSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end)
            end
        end

        local lwSlot = rootOverlay:AddChildToOverlay(leftWing)
        if Core.IsValidObj(lwSlot) then
            pcall(function()
                lwSlot:SetHorizontalAlignment(1) -- Left
                lwSlot:SetVerticalAlignment(2)   -- Center (aligned with left-center HUD bracket)
                lwSlot:SetPadding({ Left = 28.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
    end

    -- Right-Center 3rd-Person Hull Wing (seamlessly connected right next to the right-center HUD bracket)
    local rightWing = Core.CreateRawWidget("/Script/UMG.HorizontalBox", outer)
    local hullValTxt = nil
    local hullTitleTxt = nil
    local hullSegs = {} -- [1]=bottom, [2]=middle, [3]=top

    if Core.IsValidObj(rightWing) then
        pcall(function() rightWing:SetVisibility(1) end) -- Collapsed until 3rd-person active

        -- Hull numeric readout card to the left of the 3 vertical segments
        local hullPanel = Core.CreateRawWidget("/Script/UMG.Border", outer)
        local hullOuterV = Core.CreateRawWidget("/Script/UMG.VerticalBox", outer)
        local hullInnerV = Core.CreateRawWidget("/Script/UMG.VerticalBox", outer)
        if Core.IsValidObj(hullPanel) and Core.IsValidObj(hullOuterV) and Core.IsValidObj(hullInnerV) then
            pcall(function()
                hullPanel:SetBrushColor(TELEM_PANEL)
                hullPanel:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                hullPanel:SetVisibility(3)
                hullOuterV:SetVisibility(3)
                hullInnerV:SetVisibility(3)
            end)

            local hTopLine = makeHairline(TELEM_GOLD, 2.0)
            if Core.IsValidObj(hTopLine) then
                local htS = hullOuterV:AddChildToVerticalBox(hTopLine)
                if Core.IsValidObj(htS) then pcall(function() htS:SetHorizontalAlignment(0) end) end
            end

            hullTitleTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(hullTitleTxt) then
                pcall(function()
                    hullTitleTxt:SetVisibility(3)
                    hullTitleTxt:SetSize(9)
                    hullTitleTxt:SetText(Core.MakeText("HULL"))
                end)
                SetWBPTextCol(hullTitleTxt, TELEM_MUTED)
                local htlS = hullInnerV:AddChildToVerticalBox(hullTitleTxt)
                if Core.IsValidObj(htlS) then
                    pcall(function()
                        htlS:SetHorizontalAlignment(3) -- Right
                        htlS:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 2.0 })
                    end)
                end
            end

            hullValTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(hullValTxt) then
                pcall(function()
                    hullValTxt:SetVisibility(3)
                    hullValTxt:SetSize(13)
                    hullValTxt:SetText(Core.MakeText("--/--"))
                end)
                SetWBPTextCol(hullValTxt, TELEM_GOLD)
                local hvS = hullInnerV:AddChildToVerticalBox(hullValTxt)
                if Core.IsValidObj(hvS) then pcall(function() hvS:SetHorizontalAlignment(3) end) end
            end

            local hiS = hullOuterV:AddChildToVerticalBox(hullInnerV)
            if Core.IsValidObj(hiS) then
                pcall(function()
                    hiS:SetPadding({ Left = 12.0, Top = 8.0, Right = 10.0, Bottom = 8.0 })
                    hiS:SetHorizontalAlignment(3)
                end)
            end

            local hBotLine = makeHairline({ R = 0.94, G = 0.66, B = 0.10, A = 0.55 }, 1.5)
            if Core.IsValidObj(hBotLine) then
                local hbS = hullOuterV:AddChildToVerticalBox(hBotLine)
                if Core.IsValidObj(hbS) then pcall(function() hbS:SetHorizontalAlignment(0) end) end
            end

            pcall(function() hullPanel:AddChild(hullOuterV) end)
            local hpSlot = rightWing:AddChildToHorizontalBox(hullPanel)
            if Core.IsValidObj(hpSlot) then
                pcall(function()
                    hpSlot:SetVerticalAlignment(2)
                    hpSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 8.0, Bottom = 0.0 })
                end)
            end
        end

        -- 3 distinct separated vertical hull rectangles (top = [3], middle = [2], bottom = [1])
        local segsVBox = Core.CreateRawWidget("/Script/UMG.VerticalBox", outer)
        if Core.IsValidObj(segsVBox) then
            pcall(function() segsVBox:SetVisibility(3) end)
            for segIdx = 3, 1, -1 do
                local segSb = Core.CreateRawWidget("/Script/UMG.SizeBox", outer)
                local segBdr = Core.CreateRawWidget("/Script/UMG.Border", outer)
                if Core.IsValidObj(segSb) and Core.IsValidObj(segBdr) then
                    pcall(function()
                        segSb:SetWidthOverride(12.0)
                        segSb:SetHeightOverride(48.0)
                        segSb:SetVisibility(3)
                        segBdr:SetBrushColor(TELEM_GREEN)
                        segBdr:SetVisibility(3)
                        segSb:AddChild(segBdr)
                    end)
                    hullSegs[segIdx] = segBdr
                    local ss = segsVBox:AddChildToVerticalBox(segSb)
                    if Core.IsValidObj(ss) then
                        pcall(function()
                            ss:SetHorizontalAlignment(2)
                            ss:SetPadding({ Left = 0.0, Top = (segIdx == 3) and 0.0 or 6.0, Right = 0.0, Bottom = 0.0 })
                        end)
                    end
                end
            end
            local svSlot = rightWing:AddChildToHorizontalBox(segsVBox)
            if Core.IsValidObj(svSlot) then pcall(function() svSlot:SetVerticalAlignment(2) end) end
        end

        local rwSlot = rootOverlay:AddChildToOverlay(rightWing)
        if Core.IsValidObj(rwSlot) then
            pcall(function()
                rwSlot:SetHorizontalAlignment(3) -- Right
                rwSlot:SetVerticalAlignment(2)   -- Center (aligned with right-center HUD bracket)
                rwSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 28.0, Bottom = 0.0 })
            end)
        end
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
        LeftWing = leftWing,
        RightWing = rightWing,
        BoostFillSlot = boostFillSlot,
        BoostFillBorder = boostFillBorder,
        BoostLabelTxt = boostLabelTxt,
        SpeedTxt = speedTxt,
        FuelUseTxt = fuelUseTxt,
        FuelAvailTxt = fuelAvailTxt,
        HullTitleTxt = hullTitleTxt,
        HullValTxt = hullValTxt,
        HullSegs = hullSegs,
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
        if Core.IsValidObj(ui.LeftWing) then ui.LeftWing:SetVisibility(showZoom and 3 or 1) end
        if Core.IsValidObj(ui.RightWing) then ui.RightWing:SetVisibility(showZoom and 3 or 1) end
        ui.Root:SetVisibility(4) -- SelfHitTestInvisible
    end)
end

local function UpdateShipTelemetry(shipActor, shipObj, pc)
    if not (IsThirdPerson and LegendUI and Core.IsValidObj(LegendUI.LeftWing) and Core.IsValidObj(shipObj)) then
        return
    end
    local ui = LegendUI

    -- 1. Boost charge & active boosting state
    local boostCharge = nil
    local maxBoost = nil
    local isBoosting = IsShipActivelyBoosting(shipObj, pc)
    pcall(function()
        boostCharge = ReadNumericOrFixed(shipObj.BoostCharge)
        maxBoost = ReadNumericOrFixed(shipObj.MaxBoostCharge)
    end)
    local boostPct = 0.0
    if boostCharge and maxBoost and maxBoost > 0.001 then
        boostPct = Core.Clamp(boostCharge / maxBoost, 0.0, 1.0)
    elseif boostCharge then
        boostPct = Core.Clamp(boostCharge, 0.0, 1.0)
    end
    if Core.IsValidObj(ui.BoostFillSlot) then
        pcall(function() ui.BoostFillSlot:SetSize({ X = 0.0, Y = math.max(0.0, BOOST_BAR_H * boostPct) }) end)
    end
    if Core.IsValidObj(ui.BoostFillBorder) then
        local bCol = isBoosting and TELEM_BOOST or (boostPct > 0.05 and TELEM_GOLD or TELEM_DIM)
        pcall(function() ui.BoostFillBorder:SetBrushColor(bCol) end)
    end
    if Core.IsValidObj(ui.BoostLabelTxt) then
        SetWBPTextCol(ui.BoostLabelTxt, isBoosting and TELEM_BOOST or TELEM_MUTED)
    end

    -- 2. Live speed & movement direction (forward / reverse / stopped)
    local speedMs = 0.0
    local forwardDot = 0.0
    local gotVel = false
    pcall(function()
        if shipObj.Velocity then
            local vx = ReadNumericOrFixed(shipObj.Velocity.X)
            local vy = ReadNumericOrFixed(shipObj.Velocity.Y)
            local vz = ReadNumericOrFixed(shipObj.Velocity.Z)
            if vx and vy and vz then
                speedMs = math.sqrt(vx * vx + vy * vy + vz * vz)
                gotVel = true
                if Core.IsValidObj(shipActor) and shipActor.GetActorForwardVector then
                    local fwd = shipActor:GetActorForwardVector()
                    if fwd then
                        forwardDot = vx * (tonumber(fwd.X) or 0) + vy * (tonumber(fwd.Y) or 0) + vz * (tonumber(fwd.Z) or 0)
                    end
                end
            end
        end
    end)
    if not gotVel and Core.IsValidObj(shipActor) and shipActor.GetVelocity then
        pcall(function()
            local v = shipActor:GetVelocity()
            if v then
                local vx, vy, vz = tonumber(v.X) or 0, tonumber(v.Y) or 0, tonumber(v.Z) or 0
                speedMs = math.sqrt(vx * vx + vy * vy + vz * vz) / 100.0 -- Unreal cm/s -> m/s
                if shipActor.GetActorForwardVector then
                    local fwd = shipActor:GetActorForwardVector()
                    if fwd then
                        forwardDot = (vx * (tonumber(fwd.X) or 0) + vy * (tonumber(fwd.Y) or 0) + vz * (tonumber(fwd.Z) or 0)) / 100.0
                    end
                end
            end
        end)
    end
    local dirPrefix = "— "
    if speedMs >= 0.5 then
        dirPrefix = (forwardDot < -0.5) and "▼ " or "▲ "
    end
    if Core.IsValidObj(ui.SpeedTxt) then
        local spStr = string.format("%s%.0f m/s", dirPrefix, speedMs)
        pcall(function() ui.SpeedTxt:SetText(Core.MakeText(spStr)) end)
        SetWBPTextCol(ui.SpeedTxt, isBoosting and TELEM_BOOST or ((forwardDot < -0.5 and speedMs >= 0.5) and TELEM_ORANGE or TELEM_GOLD))
    end

    -- 3. Fuel usage & fuel availability
    local fuelUse = nil
    local fuelAvail = nil
    pcall(function()
        fuelUse = ReadNumericOrFixed(shipObj.FuelConsumptionRate)
        fuelAvail = ReadNumericOrFixed(shipObj.Fuel)
        if fuelAvail == nil then fuelAvail = ReadNumericOrFixed(shipObj.Energy) end
    end)
    if Core.IsValidObj(ui.FuelUseTxt) then
        local uStr = fuelUse and ("Using: " .. FormatEnergyValue(fuelUse, true)) or "Using: 0.0 MJ/s"
        pcall(function() ui.FuelUseTxt:SetText(Core.MakeText(uStr)) end)
    end
    if Core.IsValidObj(ui.FuelAvailTxt) then
        local aStr = fuelAvail and ("Fuel: " .. FormatEnergyValue(fuelAvail, false)) or "Fuel: --"
        pcall(function() ui.FuelAvailTxt:SetText(Core.MakeText(aStr)) end)
        local lowFuel = (fuelAvail ~= nil and fuelAvail <= 0.1)
        SetWBPTextCol(ui.FuelAvailTxt, lowFuel and TELEM_RED or TELEM_GOLD)
    end

    -- 4. Hull integrity & 3-segment vertical bar (3 green / 2 orange / 1 red / 3 red + red text when destroyed)
    local curHull = nil
    local maxHull = nil
    pcall(function()
        if shipObj.GetCurrentHull then curHull = ReadNumericOrFixed(shipObj:GetCurrentHull()) end
        if curHull == nil then curHull = ReadNumericOrFixed(shipObj.Hull) end
        if shipObj.GetMaxHull then maxHull = ReadNumericOrFixed(shipObj:GetMaxHull()) end
        if maxHull == nil then maxHull = ReadNumericOrFixed(shipObj.MaxHull) end
        if maxHull == nil then maxHull = ReadNumericOrFixed(shipObj.Hull) end
    end)
    if curHull ~= nil then
        local maxH = (maxHull and maxHull > 0) and maxHull or math.max(1.0, curHull)
        local pct = Core.Clamp(curHull / maxH, 0.0, 1.0)
        local isDestroyed = (curHull <= 0.001)

        if Core.IsValidObj(ui.HullValTxt) then
            pcall(function()
                ui.HullValTxt:SetText(Core.MakeText(string.format("%.0f/%.0f", math.max(0, curHull), maxH)))
            end)
            SetWBPTextCol(ui.HullValTxt, isDestroyed and TELEM_RED or TELEM_GOLD)
        end
        if Core.IsValidObj(ui.HullTitleTxt) then
            SetWBPTextCol(ui.HullTitleTxt, isDestroyed and TELEM_RED or TELEM_MUTED)
        end

        local segColors = { TELEM_EMPTY, TELEM_EMPTY, TELEM_EMPTY }
        if isDestroyed then
            segColors = { TELEM_RED, TELEM_RED, TELEM_RED }
        elseif pct > 0.66 then
            segColors = { TELEM_GREEN, TELEM_GREEN, TELEM_GREEN }
        elseif pct > 0.33 then
            segColors = { TELEM_ORANGE, TELEM_ORANGE, TELEM_EMPTY }
        else
            segColors = { TELEM_RED, TELEM_EMPTY, TELEM_EMPTY }
        end
        for i = 1, 3 do
            if ui.HullSegs and Core.IsValidObj(ui.HullSegs[i]) then
                pcall(function() ui.HullSegs[i]:SetBrushColor(segColors[i]) end)
            end
        end
    end

    if not TelemetryDiagLogged then
        TelemetryDiagLogged = true
        Core.Log(string.format("[ShipCamera] TelemetryDiag boost=%s/%s speed=%.1f fuelUse=%s fuel=%s hull=%s/%s",
            tostring(boostCharge), tostring(maxBoost), speedMs,
            tostring(fuelUse), tostring(fuelAvail), tostring(curHull), tostring(maxHull)))
    end
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

local function ReadNumericOrFixed(val)
    if type(val) == "number" then return val end
    if val ~= nil then
        local okV, raw = pcall(function() return val.Value end)
        if okV and type(raw) == "number" then
            return raw / 65536.0
        end
    end
    return nil
end

local function IsShipActivelyBoosting(shipObj, pc)
    if Core.IsValidObj(shipObj) then
        local okB, bBoosting = pcall(function() return shipObj.bBoosting end)
        if okB and type(bBoosting) == "boolean" then
            if not bBoosting then return false end
            local okC, rawCharge = pcall(function() return shipObj.BoostCharge end)
            if okC and rawCharge ~= nil then
                local charge = ReadNumericOrFixed(rawCharge)
                if charge ~= nil and charge <= 0.001 then
                    return false
                end
            end
            return true
        end
    end
    -- Fallback only if bBoosting property is unavailable
    if Core.IsValidObj(pc) and KEY_SPACE and pc.IsInputKeyDown then
        local okK, down = pcall(function() return pc:IsInputKeyDown(KEY_SPACE) == true end)
        if okK then return down end
    end
    return false
end

local ScrollPollGen = 0

-- On-demand frame-synchronized scroll/MMB/boost loop: runs ONLY while IsThirdPerson is active (learning.md §8)
local function StartScrollPoll()
    if ScrollPollActive then return end
    ScrollPollActive = true
    ScrollPollGen = ScrollPollGen + 1
    local myGen = ScrollPollGen
    local lastClock = os.clock()
    local lastTelemClock = 0.0
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

        local shipActor, shipObj = GetPilotedShipActor(pc)
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
            -- 1. Scroll-wheel manual zoom & MMB reset
            local delta = 0.0
            local mmbPressed = false
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
            end)
            local isBoosting = IsShipActivelyBoosting(shipObj, pc)

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

            -- 2. Smooth reactive boost camera (tracks actual shipObj.bBoosting & BoostCharge)
            local targetBlend = isBoosting and 1.0 or 0.0
            if math.abs(BoostBlend - targetBlend) > 0.001 then
                local rate = isBoosting and 7.5 or 4.5
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

        if (now - lastTelemClock) >= 0.08 then
            lastTelemClock = now
            pcall(UpdateShipTelemetry, shipActor, shipObj, pc)
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
