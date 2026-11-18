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

local OrigMeshState            = {} -- compAddr -> { ... }
local ProcessedHeightActors    = {} -- actorAddr -> true
local ProcessedCollisionActors = {} -- actorAddr -> true
local LoggedKeys               = {} -- key -> true
local PollActive               = false

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

local function DisableSimCollider(simObj, countsByClass)
    if not Core.IsValidObj(simObj) then return end
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

function Feature.Init()
    StartPoll()
    Core.Log("[SplitterBalancerTweaks] Initialized (bColliderEnabled=false + 2/3 (0.67x) Z height).")
end

function Feature.OnClientRestart()
    OrigMeshState = {}
    ProcessedHeightActors = {}
    ProcessedCollisionActors = {}
end

function Feature.PruneCaches()
    for addr, st in pairs(OrigMeshState) do
        if not st or not Core.IsValidObj(st.Comp) then
            OrigMeshState[addr] = nil
        end
    end
end

return Feature
