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
local SCAN_PERIOD_IDLE = 0.85

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

local WalkthroughSimIDs = {}
local TrackedSimFrames = {}
local TrackedEnvs = {}
local ProcessedEnvNums = {}
local NeedsEnvClean = false
local CustomColliderPropsReady = false
local CustomColliderPropsAttemptedInWorld = false

local function RegisterColliderCustomProperties()
    if CustomColliderPropsReady then return true end
    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
        if not LoggedKeys["custom_prop_api_missing"] then
            LoggedKeys["custom_prop_api_missing"] = true
            Core.Log("[SplitterBalancerTweaks] RegisterCustomProperty/PropertyTypes unavailable.")
        end
        return false
    end

    local okMin, errMin = pcall(RegisterCustomProperty, {
        Name = "EqolMinX",
        Type = PropertyTypes.IntProperty,
        BelongsToClass = "/Script/MainSequence.Collider",
        OffsetInternal = 0x00,
    })
    local okMax, errMax = pcall(RegisterCustomProperty, {
        Name = "EqolMaxX",
        Type = PropertyTypes.IntProperty,
        BelongsToClass = "/Script/MainSequence.Collider",
        OffsetInternal = 0x0C,
    })

    if okMin and okMax then
        CustomColliderPropsReady = true
        Core.Log("[SplitterBalancerTweaks] Registered Collider custom properties EqolMinX/EqolMaxX.")
        return true
    end

    if not LoggedKeys["custom_prop_err"] then
        LoggedKeys["custom_prop_err"] = true
        Core.Log(string.format("[SplitterBalancerTweaks] RegisterCustomProperty failed: min=(%s,%s) max=(%s,%s)",
            tostring(okMin), tostring(errMin), tostring(okMax), tostring(errMax)))
    end
    return false
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

local function LogFrameAndEnvOnce(simObj)
    if LoggedKeys["frame_diag"] or not Core.IsValidObj(simObj) then return end
    if not simObj.GetFrame then return end
    local okF, frame = pcall(function() return simObj:GetFrame() end)
    if not okF or not Core.IsValidObj(frame) then return end
    LoggedKeys["frame_diag"] = true

    pcall(function()
        if frame.GetCollisionEnv then
            local env = frame:GetCollisionEnv()
            if Core.IsValidObj(env) and env.Colliders then
                local num = env.Colliders.GetArrayNum and env.Colliders:GetArrayNum() or -1
                local c1 = (num > 0) and env.Colliders[1] or nil
                local cid = c1 and pcall(function() return c1.ColliderID end) and tostring(c1.ColliderID) or "?"
                Core.Log(string.format("[SplitterBalancerTweaks] Frame[%s] Env[%s] Colliders.Num=%s first.ColliderID=%s",
                    SafeClassName(frame), SafeClassName(env), tostring(num), cid))
            end
        end
    end)
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
                Core.Log(string.format("[SplitterBalancerTweaks] Set CDO Default__%s.bColliderEnabled = false (was true)", clsName))
            else
                Core.Log(string.format("[SplitterBalancerTweaks] CDO Default__%s.bColliderEnabled=%s", clsName, tostring(prev)))
            end
        elseif not LoggedKeys["cdo_miss_" .. clsName] then
            LoggedKeys["cdo_miss_" .. clsName] = true
            Core.Log(string.format("[SplitterBalancerTweaks] Could not resolve CDO for %s", clsName))
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

    if not CustomColliderPropsReady and not CustomColliderPropsAttemptedInWorld then
        CustomColliderPropsAttemptedInWorld = true
        RegisterColliderCustomProperties()
    end

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
                local matched = 0
                local modified = 0
                local alreadyOff = 0
                local readErr = 0
                local sampleMsg = nil

                for i = 1, num do
                    local c = cols[i]
                    if c then
                        local okId, cid = pcall(function() return c.ColliderID end)
                        if okId and type(cid) == "number" and WalkthroughSimIDs[cid] then
                            matched = matched + 1
                            if CustomColliderPropsReady then
                                local okR, oldMin, oldMax = pcall(function() return c.EqolMinX, c.EqolMaxX end)
                                if okR and type(oldMin) == "number" and type(oldMax) == "number" then
                                    if oldMin == COLLIDER_DISABLE_MIN and oldMax == COLLIDER_DISABLE_MAX then
                                        alreadyOff = alreadyOff + 1
                                    else
                                        local okW = pcall(function()
                                            c.EqolMinX = COLLIDER_DISABLE_MIN
                                            c.EqolMaxX = COLLIDER_DISABLE_MAX
                                        end)
                                        if okW then
                                            local okV, newMin, newMax = pcall(function() return c.EqolMinX, c.EqolMaxX end)
                                            if okV and newMin == COLLIDER_DISABLE_MIN and newMax == COLLIDER_DISABLE_MAX then
                                                modified = modified + 1
                                                if not sampleMsg then
                                                    sampleMsg = string.format("id=%d X:[%d..%d]->[%d..%d]", cid, oldMin, oldMax, newMin, newMax)
                                                end
                                            else
                                                readErr = readErr + 1
                                            end
                                        else
                                            readErr = readErr + 1
                                        end
                                    end
                                else
                                    readErr = readErr + 1
                                end
                            end
                        end
                    end
                end

                ProcessedEnvNums[envAddr] = num
                Core.Log(string.format("[SplitterBalancerTweaks] Env[%s] num=%d matched=%d disabled=%d alreadyOff=%d err=%d %s",
                    tostring(envAddr), num, matched, modified, alreadyOff, readErr, sampleMsg or ""))
            end)
        end
    end
end

local function DisableSimCollider(simObj, countsByClass)
    if not Core.IsValidObj(simObj) then return end
    EnsureSimCDODisabled(simObj)
    LogFrameAndEnvOnce(simObj)
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

    local primCls = Core.FindOrLoadClass("/Script/Engine.PrimitiveComponent")
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
    local actorAddr = actor:GetAddress()
    if ProcessedHeightActors[actorAddr] then return end
    ProcessedHeightActors[actorAddr] = true

    local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
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
                if not LoggedKeys[clsKey] then
                    LoggedKeys[clsKey] = true
                    Core.Log(string.format(
                        "[SplitterBalancerTweaks] Scale[%s.%s] sm=%s origZ=(loc=%.1f,scale=%.2f) -> newZ=(loc=%.1f,scale=%.2f)",
                        SafeClassName(actor), SafeName(c), SafeName(c.StaticMesh),
                        rz, sz, targetLz, targetSz))
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

    for clsName, cnt in pairs(disabledCounts) do
        Core.Log(string.format("[SplitterBalancerTweaks] Disabled bColliderEnabled on %s (count=%d)", clsName, cnt))
    end

    CleanTrackedEnvs()
end

local function StartPoll()
    if PollActive then return end
    PollActive = true
    local function Tick()
        local okTick, errTick = pcall(ScanAndApplyTweaks)
        if not okTick and not LoggedKeys["tick_err"] then
            LoggedKeys["tick_err"] = true
            Core.Log("[SplitterBalancerTweaks] ScanAndApplyTweaks err: " .. tostring(errTick))
        end
        ExecuteInGameThreadWithDelay(math.floor(SCAN_PERIOD_IDLE * 1000), Tick)
    end
    ExecuteInGameThreadWithDelay(250, Tick)
end

local function RegisterMachineObjectHook()
    if NewObjHookRegistered then return end
    NewObjHookRegistered = true
    pcall(NotifyOnNewObject, "/Script/MainSequence.DMSObject", function(obj)
        if not Core.IsValidObj(obj) then return end
        local clsName = SafeClassName(obj)
        if WALKTHROUGH_SIM_SET[clsName] then
            EnsureSimCDODisabled(obj)
            pcall(function()
                if obj.bColliderEnabled == true then
                    obj.bColliderEnabled = false
                end
            end)
            NeedsEnvClean = true
        end
    end)
end

function Feature.Init()
    RegisterColliderCustomProperties()
    RegisterMachineObjectHook()
    StartPoll()
    Core.Log("[SplitterBalancerTweaks] Initialized (CDO+instance bColliderEnabled=false, Env.Colliders override, 2/3 height).")
end

function Feature.OnClientRestart()
    OrigMeshState = {}
    ProcessedHeightActors = {}
    ProcessedCollisionActors = {}
    WalkthroughSimIDs = {}
    TrackedSimFrames = {}
    TrackedEnvs = {}
    ProcessedEnvNums = {}
    NeedsEnvClean = false
end

function Feature.PruneCaches()
    for addr, st in pairs(OrigMeshState) do
        if not st or not Core.IsValidObj(st.Comp) then
            OrigMeshState[addr] = nil
        end
    end
end

return Feature
