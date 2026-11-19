-- Eqol Feature: Splitter & Belt Balancer Overwrite Belts in Base-Game 3D Building
-- Allows placing a Splitter or Belt Balancer directly over existing Conveyor Belts during
-- normal 3D in-game building. Uses only native DMSPlayerController:AddDisassembleCommand
-- (to refund the overwritten belts) and AddBuildCommand (to consume materials & build the
-- splitter/balancer) — 100% save-safe and multiplayer-compatible.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "SplitterBeltOverwrite",
}

local CELL_CM = 100.0
local GRID_DIV = 50.0
local OverwriteInFlight = false

local function IsSplitterOrBalancerName(str)
    if type(str) ~= "string" then return false end
    local low = str:lower()
    return (low:find("splitter", 1, true) ~= nil) or (low:find("balancer", 1, true) ~= nil)
end

local function IsPlainConveyorBelt(m)
    if not Core.IsValidObj(m) then return false end
    local okC, clsName = pcall(function() return m:GetClass():GetFName():ToString() end)
    if not okC or type(clsName) ~= "string" then return false end
    local low = clsName:lower()
    return (low:find("conveyorbelt", 1, true) ~= nil) and (low:find("underground", 1, true) == nil)
end

local function GetRotatedCellDims(cellsX, cellsY, yawDeg)
    local norm = (math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4 + 4) % 4
    if norm == 1 or norm == 3 then
        return cellsY, cellsX
    end
    return cellsX, cellsY
end

local function MakeFP(v)
    return { Value = math.floor(v * 65536.0 + 0.5) }
end

local function ExtractBuilderState(pc)
    if not Core.IsValidObj(pc) then return nil end
    local builder = nil
    pcall(function() builder = pc.Builder end)
    if not Core.IsValidObj(builder) then return nil end

    local bld = nil
    for _, prop in ipairs({ "Buildable", "CurrentBuildable", "SelectedBuildable", "ActiveBuildable" }) do
        local ok, v = pcall(function() return builder[prop] end)
        if ok and Core.IsValidObj(v) then bld = v; break end
    end
    if not Core.IsValidObj(bld) then
        pcall(function()
            if Core.IsValidObj(pc.HoveredBuildable) then bld = pc.HoveredBuildable end
        end)
    end

    local previewActor = nil
    for _, prop in ipairs({ "PreviewActor", "PlacementPreview", "GhostActor", "Preview" }) do
        local ok, v = pcall(function() return builder[prop] end)
        if ok and Core.IsValidObj(v) then previewActor = v; break end
    end

    local bldName = ""
    if Core.IsValidObj(bld) then
        pcall(function() bldName = bld:GetFName():ToString() end)
    elseif Core.IsValidObj(previewActor) then
        pcall(function() bldName = previewActor:GetClass():GetFName():ToString() end)
    end

    if not IsSplitterOrBalancerName(bldName) then
        return nil
    end
    if not Core.IsValidObj(bld) or not Core.IsValidObj(previewActor) then
        return nil
    end

    local wx, wy, wz, wyaw = nil, nil, nil, 0.0
    pcall(function()
        local loc = previewActor:K2_GetActorLocation()
        if loc and type(loc.X) == "number" then
            wx, wy, wz = loc.X, loc.Y or 0.0, loc.Z or 0.0
        end
        local rot = previewActor:K2_GetActorRotation()
        if rot and type(rot.Yaw) == "number" then
            wyaw = rot.Yaw
        end
    end)
    if not wx then return nil end

    return {
        builder = builder,
        buildable = bld,
        bldName = bldName,
        wx = wx, wy = wy, wz = wz, wyaw = wyaw,
    }
end

local function TryOverwriteBeltsOnConfirmBuild(pc)
    if OverwriteInFlight or not Core.IsValidObj(pc) then return end
    local state = ExtractBuilderState(pc)
    if not state then return end

    local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
    if not inStation or not Core.IsValidObj(station) then return end

    local xform = nil
    local okB, floors, _, _, _, _, fx = pcall(StationData.BuildStationFloorMap, station, walkFrame, state.wx, state.wy, state.wz)
    if not okB or not fx then return end
    xform = fx

    local radW = math.rad(state.wyaw or 0.0)
    local lx, ly, lz, lyaw = StationData.WorldToStationLocal(xform, state.wx, state.wy, state.wz, math.cos(radW), math.sin(radW), 0.0)
    if not lx then return end

    local cellsX, cellsY = StationData.GetMachineFootprintCells(nil, state.buildable)
    local rx, ry = GetRotatedCellDims(cellsX or 1, cellsY or 1, lyaw or 0.0)
    local halfW = rx * CELL_CM * 0.5
    local halfH = ry * CELL_CM * 0.5

    -- Check all machines on this floor for footprint overlap
    StationData.InvalidateMachineCache()
    local allMachines = StationData.GetAllStationMachines(station, nil, walkFrame)
    local overlappingBelts = {}
    for _, m in ipairs(allMachines or {}) do
        if Core.IsValidObj(m) and not StationData.ShouldHideMachineOnMap(m) then
            local mx, my, mz, myaw = StationData.GetMachineLocalPosAndYaw(m, xform)
            if mx and my and mz and math.abs(mz - lz) <= 150.0 then
                local mcx, mcy = StationData.GetMachineFootprintCells(m)
                local mrx, mry = GetRotatedCellDims(mcx or 1, mcy or 1, myaw or 0.0)
                local mhw, mhh = mrx * CELL_CM * 0.5, mry * CELL_CM * 0.5
                if math.abs(lx - mx) < (halfW + mhw - 10.0) and math.abs(ly - my) < (halfH + mhh - 10.0) then
                    if not IsPlainConveyorBelt(m) then
                        -- Blocked by a non-belt machine; let vanilla build error stand
                        return
                    end
                    local mId = 0
                    pcall(function() if m.ID ~= nil then mId = tonumber(m.ID) or 0 end end)
                    if mId > 0 then
                        table.insert(overlappingBelts, mId)
                    end
                end
            end
        end
    end

    if #overlappingBelts == 0 then
        -- No belts overlapped; vanilla ConfirmBuild already handles normal placement
        return
    end

    -- Verify not blocked by a wall collider on this floor
    if floors then
        for _, fl in ipairs(floors) do
            if math.abs(fl.z - lz) <= 180.0 and fl.walls then
                for _, w in ipairs(fl.walls) do
                    if (lx + halfW - 10.0) > w.minX and (lx - halfW + 10.0) < w.maxX
                        and (ly + halfH - 10.0) > w.minY and (ly - halfH + 10.0) < w.maxY
                    then
                        return
                    end
                end
                break
            end
        end
    end

    -- Disassemble the overlapped conveyor belts via native AddDisassembleCommand (refunds belt materials),
    -- then build the Splitter / Belt Balancer via native AddBuildCommand (consumes splitter/balancer materials).
    OverwriteInFlight = true
    local frameId = 0
    local solarSysId = 0
    local chunkX, chunkY, chunkZ = 0, 0, 0
    pcall(function()
        if station.ID ~= nil then frameId = tonumber(station.ID) or 0 end
        if station.SolarSystemID ~= nil then solarSysId = tonumber(station.SolarSystemID) or 0 end
        if station.ChunkLocation then
            local cx, cy, cz = Core.GetFPVector(station.ChunkLocation)
            chunkX, chunkY, chunkZ = math.floor(cx + 0.5), math.floor(cy + 0.5), math.floor(cz + 0.5)
        end
    end)

    local gx = math.floor(lx / GRID_DIV + 0.5)
    local gy = math.floor(ly / GRID_DIV + 0.5)
    local gz = math.floor(lz / GRID_DIV + 0.5)
    local rotSteps = ((math.floor((lyaw or 0.0) / 90.0 + 0.5) % 4) + 4) % 4
    local halfRad = math.rad(rotSteps * 90.0) * 0.5
    local qz, qw = math.sin(halfRad), math.cos(halfRad)

    Core.Log(string.format("[SplitterBeltOverwrite] Replacing %d belt(s) with %s at grid=(%d,%d) h=%d rot=%d",
        #overlappingBelts, state.bldName, gx, gy, gz, rotSteps))

    for _, beltId in ipairs(overlappingBelts) do
        pcall(function() pc:AddDisassembleCommand(beltId, false) end)
    end

    local capBld = state.buildable
    ExecuteInGameThreadWithDelay(100, function()
        OverwriteInFlight = false
        local curPC = Core.GetLocalPlayerController()
        if not Core.IsValidObj(curPC) or not Core.IsValidObj(capBld) or not curPC.AddBuildCommand then return end
        local bCmd = {
            Buildable = capBld,
            Location = { X = MakeFP(lx / 100.0), Y = MakeFP(ly / 100.0), Z = MakeFP(lz / 100.0) },
            Quat = { X = MakeFP(0.0), Y = MakeFP(0.0), Z = MakeFP(qz), W = MakeFP(qw) },
            ChunkLocation = { X = chunkX, Y = chunkY, Z = chunkZ },
            SolarSystemID = solarSysId,
            AttachTargetID = frameId,
            GridTransform = {
                GridLocation = { X = gx, Y = gy },
                Height = gz,
                GridRotation = rotSteps,
            },
            Config = 0,
        }
        pcall(function() curPC:AddBuildCommand(bCmd) end)
    end)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "DMSPlayerController_ConfirmBuild_SplitterBeltOverwrite",
        "/Script/MainSequence.DMSPlayerController:ConfirmBuild",
        function(Context)
            local pc = Context and Context:get() or Core.GetLocalPlayerController()
            if Core.IsValidObj(pc) then
                ExecuteInGameThreadWithDelay(10, function()
                    TryOverwriteBeltsOnConfirmBuild(pc)
                end)
            end
        end
    )
end

return Feature
