-- Eqol Feature: Splitter & Belt Balancer Walk-Through + Compact 2/3 Height (+ Underground Belts)
-- 1. Sets bColliderEnabled = false on splitter and belt balancer simulation objects (matching
--    BP_ConveyorBeltObject_C / BP_UndergroundBeltObject_C) and ignores ECC_Pawn on their actors,
--    leaving MachineBounds / building placement intact.
-- 2. Scales splitter, belt balancer, and underground belt meshes to 2/3 height (~0.67x Z), anchored at floor Z.

local Core = require("core")

local Feature = {
    Name = "SplitterBalancerTweaks",
}

local HEIGHT_SCALE     = 2.0 / 3.0
local ECC_PAWN         = 2   -- ECollisionChannel::ECC_Pawn (WorldStatic=0, WorldDynamic=1, Pawn=2, Visibility=3)
local ECR_IGNORE       = 0   -- ECollisionResponse::ECR_Ignore
local ECR_BLOCK        = 2   -- ECollisionResponse::ECR_Block
local SCAN_PERIOD_IDLE = 8.0

local WALKTHROUGH_ACTOR_CLASSES = {
    "BP_Splitter_C",
    "BP_Splitter_2_C",
    "BP_Splitter_3_C",
    "BP_BeltBalancer_C",
    "BP_BeltBalancer_01_C",
    "BP_BeltBalancer_02_C",
    "BP_BeltBalancer_03_C",
}

local UNDERGROUND_ACTOR_CLASSES = {
    "BP_UndergroundBeltActor_C",
    "BP_UndergroundBeltActor_2_C",
    "BP_UndergroundBeltActor_3_C",
}

local WALKTHROUGH_SIM_CLASSES = {
    "BP_SplitterObject_C",
    "BP_SplitterObject_2_C",
    "BP_SplitterObject_3_C",
    "BPO_BeltBalancer_01_C",
    "BPO_BeltBalancer_02_C",
    "BPO_BeltBalancer_03_C",
}

local WALKTHROUGH_SIM_SET = {}
for _, clsName in ipairs(WALKTHROUGH_SIM_CLASSES) do
    WALKTHROUGH_SIM_SET[clsName] = true
end

local OrigMeshState            = {} -- compAddr -> { ... }
local ProcessedHeightActors    = {} -- actorAddr -> true
local ProcessedCollisionActors = {} -- actorAddr -> true
local PatchedSimCDOs           = {} -- clsName -> true
local LoggedKeys               = {} -- key -> true
local PollActive               = false
local NewObjHookRegistered     = false

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

local COLLIDER_DISABLE_MIN = 1000000000
local COLLIDER_DISABLE_MAX = -1000000000
local COLLIDER_STRIDE = 28

local WalkthroughSimIDs = {}
local TrackedSimFrames = {}
local TrackedEnvs = {}
local ProcessedEnvNums = {}
local NeedsEnvClean = false
local CachedAnchors = {}
local RegisteredSlotProps = {}

local function GetObjectClassPath(obj)
    if not Core.IsValidObj(obj) then return nil end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not Core.IsValidObj(cls) then return nil end
    local okF, full = pcall(function() return cls:GetFullName() end)
    if not okF or type(full) ~= "string" then return nil end
    return full:match("^%S+ (.+)$") or full
end

local DISALLOWED_ANCHOR_CLASSES = {
    ["/Script/CoreUObject.Object"] = true,
    ["/Script/Engine.Actor"] = true,
    ["/Script/Engine.ActorComponent"] = true,
}

local function RecordAnchorCandidate(obj)
    if not Core.IsValidObj(obj) then return end
    local addr = obj:GetAddress()
    if type(addr) ~= "number" then return end
    if CachedAnchors[addr] then return end
    local clsPath = GetObjectClassPath(obj)
    if clsPath and not DISALLOWED_ANCHOR_CLASSES[clsPath] then
        CachedAnchors[addr] = { obj = obj, addr = addr, clsPath = clsPath }
    end
end

local function FindAnchorForRange(minAddr, maxAddr, preferredEnv)
    local function Fits(entry)
        if not entry or not Core.IsValidObj(entry.obj) then return false end
        local dMin = minAddr - entry.addr
        local dMax = maxAddr - entry.addr
        return dMin >= 0 and dMax >= 0 and dMax <= 0x7FFFFFFF
    end

    if Core.IsValidObj(preferredEnv) then
        RecordAnchorCandidate(preferredEnv)
        local pAddr = preferredEnv:GetAddress()
        if type(pAddr) == "number" and Fits(CachedAnchors[pAddr]) then
            return CachedAnchors[pAddr]
        end
    end

    for _, entry in pairs(CachedAnchors) do
        if Fits(entry) then return entry end
    end

    -- Never fall back to FindAllOf("Object") or FindAllOf("ActorComponent"): enumerating all engine
    -- UObjects freezes the game thread and risks polluting core engine UClasses with custom properties.
    for _, searchCls in ipairs({ "DMSObject", "StationObject" }) do
        local ok, list = pcall(FindAllOf, searchCls)
        if ok and list then
            for i = 1, #list do
                local obj = list[i]
                if Core.IsValidObj(obj) then
                    local addr = obj:GetAddress()
                    if type(addr) == "number" then
                        local dMin = minAddr - addr
                        local dMax = maxAddr - addr
                        if dMin >= 0 and dMax >= 0 and dMax <= 0x7FFFFFFF then
                            RecordAnchorCandidate(obj)
                            if CachedAnchors[addr] then
                                return CachedAnchors[addr]
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function EnsureSlotProps(elemAddr, preferredEnv)
    local existing = RegisteredSlotProps[elemAddr]
    if existing and Core.IsValidObj(existing.anchor.obj) then
        local d = elemAddr - existing.anchor.addr
        if d == existing.baseOffset then
            return existing
        end
    end

    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
        return nil, "RegisterCustomProperty unavailable"
    end

    local anchor = FindAnchorForRange(elemAddr, elemAddr + 0x18, preferredEnv)
    if not anchor then
        return nil, string.format("no UObject anchor within +2GB below 0x%X", elemAddr)
    end

    local baseOffset = elemAddr - anchor.addr
    local tag = string.format("%X_%X", anchor.addr, baseOffset)
    local pMin = "EqolMinX_" .. tag
    local pMax = "EqolMaxX_" .. tag
    local pCid = "EqolCid_" .. tag

    local ok1, e1 = pcall(RegisterCustomProperty, {
        Name = pMin,
        Type = PropertyTypes.IntProperty,
        BelongsToClass = anchor.clsPath,
        OffsetInternal = baseOffset + 0x00,
    })
    local ok2, e2 = pcall(RegisterCustomProperty, {
        Name = pMax,
        Type = PropertyTypes.IntProperty,
        BelongsToClass = anchor.clsPath,
        OffsetInternal = baseOffset + 0x0C,
    })
    local ok3, e3 = pcall(RegisterCustomProperty, {
        Name = pCid,
        Type = PropertyTypes.IntProperty,
        BelongsToClass = anchor.clsPath,
        OffsetInternal = baseOffset + 0x18,
    })

    if not (ok1 and ok2 and ok3) then
        return nil, string.format("reg err min=(%s,%s) max=(%s,%s) cid=(%s,%s)",
            tostring(ok1), tostring(e1), tostring(ok2), tostring(e2), tostring(ok3), tostring(e3))
    end

    local slot = {
        anchor = anchor,
        baseOffset = baseOffset,
        pMin = pMin,
        pMax = pMax,
        pCid = pCid,
    }
    RegisteredSlotProps[elemAddr] = slot
    return slot
end

local function GetCDOFromUClass(uclass)
    if not Core.IsValidObj(uclass) then return nil end
    if uclass.GetDefaultObject then
        local okDef, defObj = pcall(function() return uclass:GetDefaultObject() end)
        if okDef and Core.IsValidObj(defObj) then
            return defObj
        end
    end

    local ok, full = pcall(function() return uclass:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    local objPath = full:match("^%S+ (.+)$") or full
    local pkg, clsName = objPath:match("^(.-)%.([^.]+)$")
    if not pkg or not clsName then return nil end
    if string.sub(clsName, 1, 9) == "Default__" then
        return Core.GetCDO(objPath)
    end
    return Core.GetCDO(pkg .. ".Default__" .. clsName)
end

local LastWorldAddr = nil

local function GetCurrentWorldAddr()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return nil end
    local okW, w = pcall(function() return pc:GetWorld() end)
    if okW and Core.IsValidObj(w) then
        return w:GetAddress()
    end
    return nil
end

local function EnsureSimCDODisabled(simObj)
    if not Core.IsValidObj(simObj) then return end
    local clsName = SafeClassName(simObj)
    if PatchedSimCDOs[clsName] then return end
    pcall(function()
        local cls = simObj:GetClass()
        local cdo = GetCDOFromUClass(cls)
        if Core.IsValidObj(cdo) then
            PatchedSimCDOs[clsName] = true
            local okVal, prev = pcall(function() return cdo.bColliderEnabled end)
            if okVal and prev == true then
                cdo.bColliderEnabled = false
            end
        end
    end)
end

local function TrackSimEnv(simObj)
    local sAddr = simObj:GetAddress()
    if TrackedSimFrames[sAddr] then return end
    TrackedSimFrames[sAddr] = true

    pcall(function()
        local id = simObj.ID
        if type(id) == "number" and id > 0 and not WalkthroughSimIDs[id] then
            WalkthroughSimIDs[id] = true
            NeedsEnvClean = true
        end
    end)

    pcall(function()
        if not simObj.GetFrame then return end
        local frame = simObj:GetFrame()
        if not Core.IsValidObj(frame) or not frame.GetCollisionEnv then return end
        local env = frame:GetCollisionEnv()
        if Core.IsValidObj(env) then
            local envAddr = env:GetAddress()
            if not TrackedEnvs[envAddr] then
                TrackedEnvs[envAddr] = env
                NeedsEnvClean = true
            end
        end
    end)
end

local function CleanTrackedEnvs()
    local anyID = next(WalkthroughSimIDs) ~= nil
    if not anyID then return end

    local dirty = NeedsEnvClean
    if not dirty then
        for envAddr, env in pairs(TrackedEnvs) do
            if Core.IsValidObj(env) and env.Colliders and env.Colliders.GetArrayNum then
                local curNum = tonumber(env.Colliders:GetArrayNum()) or -1
                if ProcessedEnvNums[envAddr] ~= curNum then
                    dirty = true
                    break
                end
            end
        end
    end
    if not dirty then return end

    NeedsEnvClean = false
    for envAddr, env in pairs(TrackedEnvs) do
        if not Core.IsValidObj(env) then
            TrackedEnvs[envAddr] = nil
            ProcessedEnvNums[envAddr] = nil
        else
            pcall(function()
                local cols = env.Colliders
                if not cols or not cols.GetArrayNum then return end
                local num = tonumber(cols:GetArrayNum()) or 0
                local dataAddr = cols.GetArrayDataAddress and cols:GetArrayDataAddress() or nil
                if type(dataAddr) ~= "number" or dataAddr == 0 then
                    if not LoggedKeys["no_data_addr"] then
                        LoggedKeys["no_data_addr"] = true
                        Core.Log(string.format("[SplitterBalancerTweaks] Colliders:GetArrayDataAddress unavailable: type=%s val=%s",
                            type(dataAddr), tostring(dataAddr)))
                    end
                    return
                end

                local matched = 0
                local modified = 0
                local alreadyOff = 0
                local readErr = 0
                local sampleMsg = nil
                local firstErr = nil

                for i = 1, num do
                    local c = cols[i]
                    if c then
                        local okId, cid = pcall(function() return c.ColliderID end)
                        if okId and type(cid) == "number" and WalkthroughSimIDs[cid] then
                            matched = matched + 1
                            local elemAddr = dataAddr + (i - 1) * COLLIDER_STRIDE
                            local slot, slotErr = EnsureSlotProps(elemAddr, env)
                            if not slot then
                                readErr = readErr + 1
                                if not firstErr then firstErr = slotErr end
                            else
                                local anchorObj = slot.anchor.obj
                                local okRead, gotCid, oldMin, oldMax = pcall(function()
                                    return anchorObj[slot.pCid], anchorObj[slot.pMin], anchorObj[slot.pMax]
                                end)
                                if not okRead then
                                    readErr = readErr + 1
                                    if not firstErr then firstErr = tostring(gotCid) end
                                elseif gotCid ~= cid then
                                    readErr = readErr + 1
                                    if not firstErr then
                                        firstErr = string.format("cid mismatch got=%s expected=%s at 0x%X",
                                            tostring(gotCid), tostring(cid), elemAddr)
                                    end
                                elseif oldMin == COLLIDER_DISABLE_MIN and oldMax == COLLIDER_DISABLE_MAX then
                                    alreadyOff = alreadyOff + 1
                                else
                                    local curDataAddr = cols.GetArrayDataAddress and cols:GetArrayDataAddress() or nil
                                    if curDataAddr ~= dataAddr then
                                        readErr = readErr + 1
                                        if not firstErr then firstErr = "Colliders TArray reallocated mid-pass" end
                                    else
                                        local okWrite, errW = pcall(function()
                                            anchorObj[slot.pMin] = COLLIDER_DISABLE_MIN
                                            anchorObj[slot.pMax] = COLLIDER_DISABLE_MAX
                                        end)
                                        if okWrite then
                                            local okV, newMin, newMax = pcall(function()
                                                return anchorObj[slot.pMin], anchorObj[slot.pMax]
                                            end)
                                            if okV and newMin == COLLIDER_DISABLE_MIN and newMax == COLLIDER_DISABLE_MAX then
                                                modified = modified + 1
                                                if not sampleMsg then
                                                    sampleMsg = string.format("id=%d X:[%d..%d]->[%d..%d]",
                                                        cid, oldMin, oldMax, newMin, newMax)
                                                end
                                            else
                                                readErr = readErr + 1
                                                if not firstErr then firstErr = "verify failed" end
                                            end
                                        else
                                            readErr = readErr + 1
                                            if not firstErr then firstErr = tostring(errW) end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                ProcessedEnvNums[envAddr] = num
                if readErr > 0 and not LoggedKeys["env_err"] then
                    LoggedKeys["env_err"] = true
                    Core.Log(string.format("[SplitterBalancerTweaks] Env[%s] collider write err=%d (%s)",
                        tostring(envAddr), readErr, firstErr or "?"))
                end
            end)
        end
    end
end

local function DisableSimCollider(simObj, countsByClass)
    if not Core.IsValidObj(simObj) then return end
    EnsureSimCDODisabled(simObj)
    TrackSimEnv(simObj)
    local okVal, enabled = pcall(function() return simObj.bColliderEnabled end)
    if okVal and enabled == true then
        local okSet = pcall(function() simObj.bColliderEnabled = false end)
        if okSet then
            local clsName = SafeClassName(simObj)
            countsByClass[clsName] = (countsByClass[clsName] or 0) + 1
        end
    end
end

local CachedPrimCls = nil
local CachedSmCls = nil
local ScanGeneration = 0

local function EnsureActorPawnIgnoreAndSimDisable(actor, simSeen, disabledCounts)
    local actorAddr = actor:GetAddress()
    local needCompScan = not ProcessedCollisionActors[actorAddr]

    -- Always check direct actor SimulationObject cheaply if available
    pcall(function()
        local s = actor.GetSimulationObject and actor:GetSimulationObject() or actor.SimulationObject
        if Core.IsValidObj(s) then
            local sAddr = s:GetAddress()
            if not simSeen[sAddr] then
                simSeen[sAddr] = true
                DisableSimCollider(s, disabledCounts)
            end
        end
    end)

    if not needCompScan then return end
    ProcessedCollisionActors[actorAddr] = true

    if not Core.IsValidObj(CachedPrimCls) then
        CachedPrimCls = Core.FindOrLoadClass("/Script/Engine.PrimitiveComponent")
    end
    local primCls = CachedPrimCls
    if not Core.IsValidObj(primCls) or not actor.K2_GetComponentsByClass then return end

    local comps, n = ExtractArray(actor:K2_GetComponentsByClass(primCls))
    for i = 1, n do
        local c = comps[i]
        if Core.IsValidObj(c) then
            pcall(function()
                if c.GetCollisionEnabled and c.GetCollisionResponseToChannel and c.SetCollisionResponseToChannel then
                    local colEn = tonumber(c:GetCollisionEnabled()) or 0
                    if colEn ~= 0 then
                        local resp = tonumber(c:GetCollisionResponseToChannel(ECC_PAWN))
                        if resp == ECR_BLOCK then
                            c:SetCollisionResponseToChannel(ECC_PAWN, ECR_IGNORE)
                        end
                    end
                end
                local s = c.GetSimulationObject and c:GetSimulationObject() or c.SimulationObject
                if Core.IsValidObj(s) then
                    local sAddr = s:GetAddress()
                    if not simSeen[sAddr] then
                        simSeen[sAddr] = true
                        DisableSimCollider(s, disabledCounts)
                    end
                end
            end)
        end
    end
end

local function ShouldScaleMeshComponent(comp)
    if not Core.IsValidObj(comp) then return false end
    local sm = nil
    pcall(function() sm = comp.StaticMesh end)
    if not Core.IsValidObj(sm) then return false end

    -- Skip hidden helper/trigger meshes (never call sm:GetFName(); UE4SS 0x18 crash trigger per learning.md §6)
    local hidden = false
    pcall(function() hidden = (comp.bHiddenInGame == true) end)
    if hidden then
        return false
    end
    return true
end

local function EnsureTargetHeight(actor)
    local actorAddr = actor:GetAddress()
    if ProcessedHeightActors[actorAddr] then return end
    ProcessedHeightActors[actorAddr] = true

    if not Core.IsValidObj(CachedSmCls) then
        CachedSmCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
    end
    local smCls = CachedSmCls
    if not Core.IsValidObj(smCls) or not actor.K2_GetComponentsByClass then return end

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
                    -- Always read baseline transform from the unmodified archetype/template component
                    -- so scaling can never compound across restarts or cache refreshes.
                    local src = c.GetArchetype and c:GetArchetype() or nil
                    if not Core.IsValidObj(src) then src = c end

                    local rl = src.RelativeLocation or c.RelativeLocation
                    if rl then
                        rx = tonumber(rl.X) or 0.0
                        ry = tonumber(rl.Y) or 0.0
                        rz = tonumber(rl.Z) or 0.0
                    end
                    local rs = src.RelativeScale3D or c.RelativeScale3D
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
            end

            pcall(function()
                if c.SetMobility and c.Mobility ~= 2 then
                    pcall(function() c:SetMobility(2) end) -- EComponentMobility::Movable
                end
                local curRs = c.RelativeScale3D
                local curSz = curRs and (tonumber(curRs.Z) or 1.0) or 1.0
                if math.abs(curSz - st.TargetScaleZ) > 0.005 then
                    c:SetRelativeScale3D({ X = st.OrigScaleX, Y = st.OrigScaleY, Z = st.TargetScaleZ })
                end
                local curRl = c.RelativeLocation
                local curLz = curRl and (tonumber(curRl.Z) or 0.0) or 0.0
                if math.abs(curLz - st.TargetLocZ) > 0.05 then
                    c:K2_SetRelativeLocation({ X = st.OrigLocX, Y = st.OrigLocY, Z = st.TargetLocZ }, false, {}, false)
                end
            end)
        end
    end
end

local function ScanAndApplyTweaks()
    local simSeen = {}
    local disabledCounts = {}

    for _, clsShort in ipairs(WALKTHROUGH_ACTOR_CLASSES) do
        local ok, list = pcall(FindAllOf, clsShort)
        if ok and list then
            for _, actor in ipairs(list) do
                if Core.IsValidObj(actor) then
                    EnsureActorPawnIgnoreAndSimDisable(actor, simSeen, disabledCounts)
                    EnsureTargetHeight(actor)
                end
            end
        end
    end

    for _, simCls in ipairs(WALKTHROUGH_SIM_CLASSES) do
        local ok, list = pcall(FindAllOf, simCls)
        if ok and list then
            for _, s in ipairs(list) do
                if Core.IsValidObj(s) then
                    local sAddr = s:GetAddress()
                    if not simSeen[sAddr] then
                        simSeen[sAddr] = true
                        DisableSimCollider(s, disabledCounts)
                    end
                end
            end
        end
    end

    for _, clsShort in ipairs(UNDERGROUND_ACTOR_CLASSES) do
        local ok, list = pcall(FindAllOf, clsShort)
        if ok and list then
            for _, actor in ipairs(list) do
                if Core.IsValidObj(actor) then
                    EnsureTargetHeight(actor)
                end
            end
        end
    end

    CleanTrackedEnvs()
end

local function ResetWorldCaches()
    ScanGeneration = ScanGeneration + 1
    OrigMeshState = {}
    ProcessedHeightActors = {}
    ProcessedCollisionActors = {}
    WalkthroughSimIDs = {}
    TrackedSimFrames = {}
    TrackedEnvs = {}
    ProcessedEnvNums = {}
    CachedAnchors = {}
    RegisteredSlotProps = {}
    CachedPrimCls = nil
    CachedSmCls = nil
    NeedsEnvClean = false
end

local StaggeredScanActive = false
local StaggeredScanPending = false

local function RunStaggeredScan()
    if StaggeredScanActive then
        StaggeredScanPending = true
        return
    end
    StaggeredScanActive = true
    StaggeredScanPending = false
    local myGen = ScanGeneration

    -- Build a flat list of single-class scan tasks so we never run 16 FindAllOf calls in one frame
    local tasks = {}
    for _, clsShort in ipairs(WALKTHROUGH_ACTOR_CLASSES) do
        tasks[#tasks + 1] = { kind = "walk_actor", cls = clsShort }
    end
    for _, simCls in ipairs(WALKTHROUGH_SIM_CLASSES) do
        tasks[#tasks + 1] = { kind = "walk_sim", cls = simCls }
    end
    for _, clsShort in ipairs(UNDERGROUND_ACTOR_CLASSES) do
        tasks[#tasks + 1] = { kind = "ug_actor", cls = clsShort }
    end

    local simSeen = {}
    local disabledCounts = {}
    local idx = 1

    local function Step()
        if myGen ~= ScanGeneration then
            StaggeredScanActive = false
            return
        end
        if idx <= #tasks then
            local t = tasks[idx]
            idx = idx + 1
            local ok, list = pcall(FindAllOf, t.cls)
            if ok and list then
                if t.kind == "walk_actor" then
                    for _, actor in ipairs(list) do
                        if Core.IsValidObj(actor) then
                            EnsureActorPawnIgnoreAndSimDisable(actor, simSeen, disabledCounts)
                            EnsureTargetHeight(actor)
                        end
                    end
                elseif t.kind == "walk_sim" then
                    for _, s in ipairs(list) do
                        if Core.IsValidObj(s) then
                            local sAddr = s:GetAddress()
                            if not simSeen[sAddr] then
                                simSeen[sAddr] = true
                                DisableSimCollider(s, disabledCounts)
                            end
                        end
                    end
                elseif t.kind == "ug_actor" then
                    for _, actor in ipairs(list) do
                        if Core.IsValidObj(actor) then
                            EnsureTargetHeight(actor)
                        end
                    end
                end
            end
            ExecuteInGameThreadAfterFrames(2, Step)
        else
            pcall(CleanTrackedEnvs)
            StaggeredScanActive = false
            if StaggeredScanPending and myGen == ScanGeneration then
                StaggeredScanPending = false
                ExecuteInGameThreadWithDelay(300, RunStaggeredScan)
            end
        end
    end

    ExecuteInGameThreadAfterFrames(1, Step)
end

local DebouncedScanScheduled = false
local function ScheduleStaggeredScan(delayMs)
    if DebouncedScanScheduled then return end
    DebouncedScanScheduled = true
    local myGen = ScanGeneration
    ExecuteInGameThreadWithDelay(delayMs or 400, function()
        DebouncedScanScheduled = false
        if myGen == ScanGeneration then
            RunStaggeredScan()
        end
    end)
end

local UNDERGROUND_SIM_SET = {
    BP_UndergroundBeltObject_C = true,
    BP_UndergroundBeltObject_2_C = true,
    BP_UndergroundBeltObject_3_C = true,
}

local function ApplyDirectToMachineActors(obj, isWalk)
    if not Core.IsValidObj(obj) then return false end
    local foundActor = false
    local simSeen = {}
    local disabledCounts = {}

    local function handleActor(a)
        if not Core.IsValidObj(a) then return end
        foundActor = true
        if isWalk then
            EnsureActorPawnIgnoreAndSimDisable(a, simSeen, disabledCounts)
        end
        EnsureTargetHeight(a)
    end

    pcall(function()
        if Core.IsValidObj(obj.Actor) then
            handleActor(obj.Actor)
        end
        if obj.Actors then
            local arr, n = ExtractArray(obj.Actors)
            for i = 1, n do
                handleActor(arr[i])
            end
        end
    end)
    return foundActor
end

local function RegisterMachineObjectHook()
    if NewObjHookRegistered then return end
    NewObjHookRegistered = true
    local function HandleNewMachineObj(obj)
        if not Core.IsValidObj(obj) then return end
        local clsName = SafeClassName(obj)
        local low = clsName:lower()
        local isWalk = WALKTHROUGH_SIM_SET[clsName]
            or low:find("splitter", 1, true) ~= nil
            or low:find("beltbalancer", 1, true) ~= nil
        local isUg = UNDERGROUND_SIM_SET[clsName]
            or low:find("undergroundbelt", 1, true) ~= nil
        if not isWalk and not isUg then return end

        local myGen = ScanGeneration
        ExecuteInGameThreadWithDelay(150, function()
            if myGen ~= ScanGeneration or not Core.IsValidObj(obj) then return end
            if isWalk then
                EnsureSimCDODisabled(obj)
                DisableSimCollider(obj, {})
                pcall(CleanTrackedEnvs)
            end
            if not ApplyDirectToMachineActors(obj, isWalk) then
                -- Actor may spawn a moment after the simulation object; retry direct lookup once before falling back
                ExecuteInGameThreadWithDelay(400, function()
                    if myGen ~= ScanGeneration or not Core.IsValidObj(obj) then return end
                    if not ApplyDirectToMachineActors(obj, isWalk) then
                        ScheduleStaggeredScan(300)
                    end
                end)
            end
        end)
    end
    -- MachineObject is the true base class for newly built splitters, balancers, and underground belts
    pcall(NotifyOnNewObject, "/Script/MainSequence.MachineObject", HandleNewMachineObj)
end

function Feature.Init()
    LastWorldAddr = GetCurrentWorldAddr()
    RegisterMachineObjectHook()
    ScheduleStaggeredScan(1500)
    Core.Log("[SplitterBalancerTweaks] Initialized.")
end

function Feature.OnClientRestart()
    local curWorld = GetCurrentWorldAddr()
    if curWorld == nil or curWorld ~= LastWorldAddr then
        LastWorldAddr = curWorld
        ResetWorldCaches()
    end
    ScheduleStaggeredScan(1800)
end

function Feature.OnMapLoad()
    LastWorldAddr = GetCurrentWorldAddr()
    ResetWorldCaches()
    ScheduleStaggeredScan(2500)
end

function Feature.PruneCaches()
    for addr, st in pairs(OrigMeshState) do
        if not st or not Core.IsValidObj(st.Comp) then
            OrigMeshState[addr] = nil
        end
    end
    for addr, entry in pairs(CachedAnchors) do
        if not entry or not Core.IsValidObj(entry.obj) then
            CachedAnchors[addr] = nil
        end
    end
    for addr, frame in pairs(TrackedSimFrames) do
        if not Core.IsValidObj(frame) then
            TrackedSimFrames[addr] = nil
        end
    end
    for addr, env in pairs(TrackedEnvs) do
        if not Core.IsValidObj(env) then
            TrackedEnvs[addr] = nil
            ProcessedEnvNums[addr] = nil
        end
    end
    for elemAddr, entry in pairs(RegisteredSlotProps) do
        if not entry or not entry.anchor or not Core.IsValidObj(entry.anchor.obj) then
            RegisteredSlotProps[elemAddr] = nil
        end
    end
end

return Feature
