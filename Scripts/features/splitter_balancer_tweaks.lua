-- Eqol Feature: Splitter & Belt Balancer Walk-Through + Compact 2/3 Height
-- 1. Allows players to walk through splitters and belt balancers (ignores Pawn/movement channels +
--    MoveIgnoreActors) while keeping WorldStatic/WorldDynamic/Trace channels blocking for building placement.
-- 2. Scales splitter and belt balancer housing meshes to 2/3 height (~0.67x Z), anchored at floor Z.

local Core = require("core")

local Feature = {
    Name = "SplitterBalancerTweaks",
}

local HEIGHT_SCALE     = 2.0 / 3.0
local ECC_PAWN         = 2   -- ECollisionChannel::ECC_Pawn (WorldStatic=0, WorldDynamic=1, Pawn=2, Visibility=3)
local ECR_IGNORE       = 0   -- ECollisionResponse::ECR_Ignore
local ECR_BLOCK        = 2   -- ECollisionResponse::ECR_Block
local SCAN_PERIOD_IDLE = 0.45

local TARGET_ACTOR_CLASSES = {
    "BP_Splitter_C",
    "BP_Splitter_2_C",
    "BP_Splitter_3_C",
    "BP_BeltBalancer_C",
    "BP_BeltBalancer_01_C",
    "BP_BeltBalancer_02_C",
    "BP_BeltBalancer_03_C",
}

local REF_ACTOR_CLASSES = {
    "BP_ConveyorBelt_C",
    "BP_UndergroundBeltActor_C",
}

local OrigMeshState     = {} -- compAddr -> { ... }
local IgnoredPawnActors = {} -- pawnAddr -> { actorAddr -> true }
local LoggedClasses     = {} -- key -> true
local PollActive        = false

local function SafeName(obj)
    if not Core.IsValidObj(obj) then return "nil" end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return (ok and type(n) == "string") and n or "?"
end

local function SafeClassName(obj)
    if not Core.IsValidObj(obj) then return "nil" end
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return (ok and type(n) == "string") and n or "?"
end

local function ExtractArray(tarr)
    local out = {}
    local count = 0
    if not tarr then return out, 0 end
    local okLen, len = pcall(function()
        return tarr.GetArrayNum and tarr:GetArrayNum() or #tarr
    end)
    if okLen and type(len) == "number" then
        for i = 1, len do
            local okE, elem = pcall(function() return tarr[i] end)
            if okE and elem ~= nil then
                local unwrapped = Core.UnwrapArrayElem(elem)
                if unwrapped then
                    count = i
                    out[i] = unwrapped
                end
            end
        end
        return out, count
    end
    pcall(function()
        tarr:ForEach(function(idx, elem)
            local unwrapped = Core.UnwrapArrayElem(elem)
            if unwrapped then
                if idx > count then count = idx end
                out[idx] = unwrapped
            end
        end)
    end)
    return out, count
end

local function DescribeChannels(comp)
    if not Core.IsValidObj(comp) or not comp.GetCollisionResponseToChannel then return "n/a" end
    local parts = {}
    for ch = 0, 31 do
        local okR, r = pcall(function() return comp:GetCollisionResponseToChannel(ch) end)
        if okR and type(r) == "number" and r ~= 0 then
            parts[#parts + 1] = string.format("ch%d=%d", ch, r)
        end
    end
    return (#parts > 0) and table.concat(parts, ",") or "allIgnore"
end

local function LogActorCollisionDiag(actor, tag)
    if not Core.IsValidObj(actor) then return end
    local clsName = SafeClassName(actor)
    local key = tag .. ":" .. clsName
    if LoggedClasses[key] then return end
    LoggedClasses[key] = true

    local primCls = Core.FindOrLoadClass("/Script/Engine.PrimitiveComponent")
    if not Core.IsValidObj(primCls) or not actor.K2_GetComponentsByClass then return end

    local comps, n = ExtractArray(actor:K2_GetComponentsByClass(primCls))
    local details = {}
    for i = 1, n do
        local c = comps[i]
        if Core.IsValidObj(c) then
            local colEn = -1
            local objType = -1
            local prof = "?"
            local smName = ""
            pcall(function()
                if c.GetCollisionEnabled then colEn = tonumber(c:GetCollisionEnabled()) or -1 end
                if c.GetCollisionObjectType then objType = tonumber(c:GetCollisionObjectType()) or -1 end
                if c.GetCollisionProfileName then prof = tostring(c:GetCollisionProfileName():ToString()) end
                if c.StaticMesh and Core.IsValidObj(c.StaticMesh) then
                    smName = " mesh=" .. SafeName(c.StaticMesh)
                end
            end)
            details[#details + 1] = string.format("%s(%s%s col=%d type=%d prof=%s [%s])",
                SafeName(c), SafeClassName(c), smName, colEn, objType, prof, DescribeChannels(c))
        end
    end
    Core.Log(string.format("[SplitterBalancerTweaks] Diag[%s %s] comps(%d): %s",
        tag, clsName, n, table.concat(details, " | ")))
end

local function ResolveActivePawn()
    local pc = Core.GetLocalPlayerController()
    local pawn = Core.IsValidObj(pc) and pc.Pawn or nil
    if Core.IsValidObj(pawn) and SafeClassName(pawn) ~= "BP_MainMenuPawn_C" then
        return pawn
    end

    local okChars, chars = pcall(FindAllOf, "BP_Character_C")
    if okChars and chars then
        for _, ch in ipairs(chars) do
            if Core.IsValidObj(ch) then
                local okLoc, isLoc = pcall(function()
                    return ch.IsLocallyControlled and ch:IsLocallyControlled()
                end)
                if okLoc and isLoc == true then
                    return ch
                end
            end
        end
        for _, ch in ipairs(chars) do
            if Core.IsValidObj(ch) then
                return ch
            end
        end
    end
    return pawn
end

local function LogPawnExtraDiag(pawn)
    local clsName = SafeClassName(pawn)
    local key = "pawnextra:" .. clsName
    if LoggedClasses[key] then return end
    LoggedClasses[key] = true

    local moveInfo = "nil"
    pcall(function()
        local cm = pawn.CharacterMovement
        if Core.IsValidObj(cm) then
            local upd = Core.IsValidObj(cm.UpdatedComponent) and SafeName(cm.UpdatedComponent) or "nil"
            local stepH = tonumber(cm.MaxStepHeight) or -1
            local mode = tonumber(cm.MovementMode) or -1
            moveInfo = string.format("updated=%s stepH=%.1f mode=%d", upd, stepH, mode)
        end
    end)

    local attachedNames = {}
    pcall(function()
        if pawn.GetAttachedActors then
            local arr, cnt = ExtractArray(pawn:GetAttachedActors())
            for i = 1, cnt do
                attachedNames[#attachedNames + 1] = SafeClassName(arr[i])
            end
        end
    end)

    Core.Log(string.format("[SplitterBalancerTweaks] PawnExtra[%s] move=(%s) attached(%d)=[%s]",
        clsName, moveInfo, #attachedNames, table.concat(attachedNames, ",")))
end

local function GetPawnCollisionContext()
    local pawn = ResolveActivePawn()
    if not Core.IsValidObj(pawn) then return nil, {}, { [ECC_PAWN] = true } end

    local primCls = Core.FindOrLoadClass("/Script/Engine.PrimitiveComponent")
    if not Core.IsValidObj(primCls) or not pawn.K2_GetComponentsByClass then
        return pawn, {}, { [ECC_PAWN] = true }
    end

    LogActorCollisionDiag(pawn, "pawn")
    LogPawnExtraDiag(pawn)

    local comps, n = ExtractArray(pawn:K2_GetComponentsByClass(primCls))
    local pawnComps = {}
    local ignoreChannels = { [ECC_PAWN] = true }
    for i = 1, n do
        local c = comps[i]
        if Core.IsValidObj(c) then
            pawnComps[#pawnComps + 1] = c
            pcall(function()
                local colEn = c.GetCollisionEnabled and tonumber(c:GetCollisionEnabled()) or 0
                if colEn ~= 0 and c.GetCollisionObjectType then
                    local ot = tonumber(c:GetCollisionObjectType())
                    -- Include Pawn's own movement collider channel (e.g. ECC_Pawn=2 or custom movement channel),
                    -- never generic WorldStatic(0) or WorldDynamic(1).
                    if ot and ot >= 2 then
                        ignoreChannels[ot] = true
                    end
                end
            end)
        end
    end

    return pawn, pawnComps, ignoreChannels
end

local function FormatChannelSet(setTbl)
    local keys = {}
    for ch, enabled in pairs(setTbl) do
        if enabled then keys[#keys + 1] = ch end
    end
    table.sort(keys)
    local s = {}
    for _, ch in ipairs(keys) do s[#s + 1] = tostring(ch) end
    return table.concat(s, ",")
end

local function EnsureWalkThroughCollision(actor, pawn, pawnComps, ignoreChannels)
    local primCls = Core.FindOrLoadClass("/Script/Engine.PrimitiveComponent")
    if not Core.IsValidObj(primCls) or not actor.K2_GetComponentsByClass then return false end

    local changed = false
    local comps, n = ExtractArray(actor:K2_GetComponentsByClass(primCls))
    local pawnCls = SafeClassName(pawn)
    local actorCls = SafeClassName(actor)
    local isLivePawn = Core.IsValidObj(pawn) and pawnCls ~= "BP_MainMenuPawn_C"
    local pawnAddr = isLivePawn and pawn:GetAddress() or nil
    local actorAddr = actor:GetAddress()
    local needIgnorePair = pawnAddr and not (IgnoredPawnActors[pawnAddr] and IgnoredPawnActors[pawnAddr][actorAddr])
    local actorIgnErr, pawnIgnErr = nil, nil
    local actorIgnCount, pawnIgnCount = 0, 0

    for i = 1, n do
        local c = comps[i]
        if Core.IsValidObj(c) and c.GetCollisionEnabled and c.GetCollisionResponseToChannel and c.SetCollisionResponseToChannel then
            pcall(function()
                local colEn = tonumber(c:GetCollisionEnabled()) or 0
                if colEn ~= 0 then
                    for ch, _ in pairs(ignoreChannels) do
                        local resp = tonumber(c:GetCollisionResponseToChannel(ch))
                        if resp == ECR_BLOCK then
                            c:SetCollisionResponseToChannel(ch, ECR_IGNORE)
                            changed = true
                        end
                    end
                    if needIgnorePair and c.IgnoreActorWhenMoving then
                        local okA, errA = pcall(function() c:IgnoreActorWhenMoving(pawn, true) end)
                        if okA then actorIgnCount = actorIgnCount + 1 else actorIgnErr = tostring(errA) end
                    end
                end
            end)
        end
    end

    if needIgnorePair then
        IgnoredPawnActors[pawnAddr] = IgnoredPawnActors[pawnAddr] or {}
        IgnoredPawnActors[pawnAddr][actorAddr] = true
        for _, pcComp in ipairs(pawnComps) do
            if Core.IsValidObj(pcComp) and pcComp.IgnoreActorWhenMoving then
                local okP, errP = pcall(function() pcComp:IgnoreActorWhenMoving(actor, true) end)
                if okP then pawnIgnCount = pawnIgnCount + 1 else pawnIgnErr = tostring(errP) end
            end
        end
    end

    local attachedKey = "attached:" .. actorCls
    if not LoggedClasses[attachedKey] then
        LoggedClasses[attachedKey] = true
        local attachedNames = {}
        pcall(function()
            if actor.GetAttachedActors then
                local arr, cnt = ExtractArray(actor:GetAttachedActors())
                for i = 1, cnt do
                    attachedNames[#attachedNames + 1] = SafeClassName(arr[i])
                end
            end
        end)
        if #attachedNames > 0 then
            Core.Log(string.format("[SplitterBalancerTweaks] Attached[%s] (%d): %s",
                actorCls, #attachedNames, table.concat(attachedNames, ",")))
        end
    end

    if isLivePawn and (changed or needIgnorePair) then
        local logKey = "apply:" .. pawnCls .. ":" .. actorCls
        if not LoggedClasses[logKey] then
            LoggedClasses[logKey] = true
            Core.Log(string.format(
                "[SplitterBalancerTweaks] AppliedWalk[%s -> %s] ch=[%s] changed=%s ignA=%d(%s) ignP=%d(%s)",
                pawnCls, actorCls, FormatChannelSet(ignoreChannels), tostring(changed),
                actorIgnCount, tostring(actorIgnErr or "ok"),
                pawnIgnCount, tostring(pawnIgnErr or "ok")))
        end
    end

    return changed
end

local function ShouldScaleMeshComponent(comp)
    if not Core.IsValidObj(comp) then return false end
    local sm = nil
    pcall(function() sm = comp.StaticMesh end)
    if not Core.IsValidObj(sm) then return false end

    local hidden = false
    pcall(function() hidden = (comp.bHiddenInGame == true) end)
    local smName = SafeName(sm)
    -- Skip hidden helper/trigger cubes; scale the actual model meshes (and any visible hull parts)
    if hidden and smName == "Cube" then
        return false
    end
    return true
end

local function EnsureTargetHeight(actor)
    local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
    if not Core.IsValidObj(smCls) or not actor.K2_GetComponentsByClass then return false end

    local changed = false
    local comps, n = ExtractArray(actor:K2_GetComponentsByClass(smCls))
    for i = 1, n do
        local c = comps[i]
        if ShouldScaleMeshComponent(c) then
            local cAddr = c:GetAddress()
            local st = OrigMeshState[cAddr]
            if not st then
                local rx, ry, rz = 0.0, 0.0, 0.0
                local sx, sy, sz = 1.0, 1.0, 1.0
                local oz, ez = 0.0, 0.0
                pcall(function()
                    local rl = c.RelativeLocation
                    if rl then
                        rx = tonumber(rl.X) or 0.0
                        ry = tonumber(rl.Y) or 0.0
                        rz = tonumber(rl.Z) or 0.0
                    end
                    local rs = c.RelativeScale3D
                    if rs then
                        sx = tonumber(rs.X) or 1.0
                        sy = tonumber(rs.Y) or 1.0
                        sz = tonumber(rs.Z) or 1.0
                    end
                    local sm = c.StaticMesh
                    if Core.IsValidObj(sm) and sm.ExtendedBounds then
                        local eb = sm.ExtendedBounds
                        if eb.Origin then oz = tonumber(eb.Origin.Z) or 0.0 end
                        if eb.BoxExtent then ez = tonumber(eb.BoxExtent.Z) or 0.0 end
                    end
                end)

                local targetSz = sz * HEIGHT_SCALE
                local targetLz = rz
                -- Only compensate RelativeLocation.Z if the mesh pivot is centered (not at floor Z=0)
                if ez > 15.0 and math.abs(oz - ez) > 2.0 then
                    local bottomZ = rz + (oz - ez) * sz
                    targetLz = bottomZ - (oz - ez) * targetSz
                end

                st = {
                    Comp = c,
                    OrigLocX = rx,
                    OrigLocY = ry,
                    OrigLocZ = rz,
                    OrigScaleX = sx,
                    OrigScaleY = sy,
                    OrigScaleZ = sz,
                    TargetScaleZ = targetSz,
                    TargetLocZ = targetLz,
                }
                OrigMeshState[cAddr] = st

                local clsKey = "mesh:" .. SafeClassName(actor) .. ":" .. SafeName(c)
                if not LoggedClasses[clsKey] then
                    LoggedClasses[clsKey] = true
                    Core.Log(string.format(
                        "[SplitterBalancerTweaks] Scale[%s.%s] sm=%s origZ=(loc=%.1f,scale=%.2f) boundsZ=(orig=%.1f,ext=%.1f) -> newZ=(loc=%.1f,scale=%.2f)",
                        SafeClassName(actor), SafeName(c), SafeName(c.StaticMesh),
                        rz, sz, oz, ez, targetLz, targetSz))
                end
            end

            pcall(function()
                if c.SetMobility and c.Mobility ~= 2 then
                    pcall(function() c:SetMobility(2) end) -- EComponentMobility::Movable
                end
                local curRs = c.RelativeScale3D
                local curSz = curRs and (tonumber(curRs.Z) or 1.0) or 1.0
                if math.abs(curSz - st.TargetScaleZ) > 0.005 then
                    c:SetRelativeScale3D({ X = st.OrigScaleX, Y = st.OrigScaleY, Z = st.TargetScaleZ })
                    changed = true
                end
                local curRl = c.RelativeLocation
                local curLz = curRl and (tonumber(curRl.Z) or 0.0) or 0.0
                if math.abs(curLz - st.TargetLocZ) > 0.05 then
                    c:K2_SetRelativeLocation({ X = st.OrigLocX, Y = st.OrigLocY, Z = st.TargetLocZ }, false, {}, false)
                    changed = true
                end
            end)
        end
    end
    return changed
end

local function ProcessRefDiagnostics()
    for _, clsShort in ipairs(REF_ACTOR_CLASSES) do
        if not LoggedClasses["ref:" .. clsShort] then
            local ok, list = pcall(FindAllOf, clsShort)
            if ok and list and #list > 0 and Core.IsValidObj(list[1]) then
                LogActorCollisionDiag(list[1], "ref")
            end
        end
    end
end

local function ScanAndApplyTweaks()
    ProcessRefDiagnostics()
    local pawn, pawnComps, ignoreChannels = GetPawnCollisionContext()

    for _, clsShort in ipairs(TARGET_ACTOR_CLASSES) do
        local ok, list = pcall(FindAllOf, clsShort)
        if ok and list then
            for _, actor in ipairs(list) do
                if Core.IsValidObj(actor) then
                    LogActorCollisionDiag(actor, "before")
                    local colChanged = EnsureWalkThroughCollision(actor, pawn, pawnComps, ignoreChannels)
                    local scaleChanged = EnsureTargetHeight(actor)
                    if colChanged or scaleChanged then
                        local afterTag = (SafeClassName(pawn) ~= "BP_MainMenuPawn_C" and Core.IsValidObj(pawn)) and ("after_" .. SafeClassName(pawn)) or "after"
                        LogActorCollisionDiag(actor, afterTag)
                    end
                end
            end
        end
    end
end

local function StartPoll()
    if PollActive then return end
    PollActive = true
    local function Tick()
        pcall(ScanAndApplyTweaks)
        ExecuteInGameThreadWithDelay(math.floor(SCAN_PERIOD_IDLE * 1000), Tick)
    end
    ExecuteInGameThreadWithDelay(200, Tick)
end

function Feature.Init()
    StartPoll()
    Core.Log("[SplitterBalancerTweaks] Initialized (Pawn walk-through + 2/3 (0.67x) Z housing height).")
end

function Feature.OnClientRestart()
    OrigMeshState = {}
    IgnoredPawnActors = {}
end

function Feature.PruneCaches()
    for addr, st in pairs(OrigMeshState) do
        if not st or not Core.IsValidObj(st.Comp) then
            OrigMeshState[addr] = nil
        end
    end
end

return Feature
