-- Eqol Feature: Elevator Floor Hotkeys
-- Press 1-9 (or 0 for floor 10) while inside an elevator (with or without its UI open)
-- to immediately send the elevator to that floor.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name = "ElevatorHotkeys",
}

local PATHS = {
    SetConfigInputCDO = "/Script/MainSequence.Default__SetConfigInput",
}

local POD_MAX_XY_DIST_SQ = 240.0 * 240.0
local POD_MIN_DZ = -160.0
local POD_MAX_DZ = 360.0

local function ResolveBottomElevator(elevObj)
    if not Core.IsValidObj(elevObj) then return nil end
    local bottom = elevObj
    pcall(function()
        if elevObj.GetBottomElevator then
            local b = elevObj:GetBottomElevator()
            if Core.IsValidObj(b) then
                bottom = b
            end
        end
    end)
    return bottom
end

local function ResolveStackIndexForFloor(elevObj, floorNum)
    local bottom = ResolveBottomElevator(elevObj)
    if not Core.IsValidObj(bottom) then return nil, nil end

    local okStack, stack = pcall(function() return bottom.ElevatorStack end)
    if not okStack or not stack then return nil, nil end

    local displayFloor = 0
    local arrayIdx = -1
    local targetStackIdx = nil

    StationData.ForEachArray(stack, function(_, elem)
        arrayIdx = arrayIdx + 1
        if targetStackIdx ~= nil then return end

        local stopObj = Core.UnwrapArrayElem(elem)
        if not Core.IsValidObj(stopObj) then return end

        local isStop = false
        pcall(function() isStop = (stopObj.bIsElevatorStop == true) end)
        if not isStop then return end

        displayFloor = displayFloor + 1
        if displayFloor == floorNum then
            local sIdx = nil
            local okIdx, res = pcall(function()
                if stopObj.GetIndexInStack then
                    return stopObj:GetIndexInStack()
                end
                return nil
            end)
            if okIdx and type(res) == "number" then
                sIdx = res
            else
                sIdx = arrayIdx
            end
            targetStackIdx = sIdx
        end
    end)

    if targetStackIdx == nil then
        return nil, nil
    end
    return bottom, targetStackIdx
end

local function ExtractElevatorObjectFromActor(elevActor, podActor)
    local eObj = nil
    pcall(function()
        if Core.IsValidObj(elevActor.ElevatorObject) then
            eObj = elevActor.ElevatorObject
        end
    end)
    if Core.IsValidObj(eObj) then return eObj end

    pcall(function()
        if elevActor.GetSimulationObject then
            local sim = elevActor:GetSimulationObject()
            if Core.IsValidObj(sim) then eObj = sim end
        end
    end)
    if Core.IsValidObj(eObj) then return eObj end

    if Core.IsValidObj(podActor) then
        pcall(function()
            if Core.IsValidObj(podActor.ConsoleInteraction) and Core.IsValidObj(podActor.ConsoleInteraction.MachineObject) then
                eObj = podActor.ConsoleInteraction.MachineObject
            end
        end)
    end
    return eObj
end

local function FindActivePlayerElevator(pc)
    -- Check 1: Open WBP_Elevator_C UI
    local okWidgets, widgets = pcall(FindAllOf, "WBP_Elevator_C")
    if okWidgets and widgets then
        for _, w in ipairs(widgets) do
            if Core.IsValidObj(w) then
                local okVis, isVis = pcall(function() return w:IsVisible() end)
                if okVis and isVis and Core.IsValidObj(w.ElevatorObject) then
                    return w.ElevatorObject, w
                end
            end
        end
    end

    -- Check 2: Player standing inside an elevator pod in normal gameplay
    local showCursor = false
    pcall(function() showCursor = (pc.bShowMouseCursor == true) end)
    if showCursor then return nil, nil end

    local isPiloting = false
    pcall(function()
        if Core.IsValidObj(pc.PlayerObject) and Core.IsValidObj(pc.PlayerObject.PilotedShip) then
            isPiloting = true
        end
    end)
    if isPiloting then return nil, nil end

    local pawn = pc.Pawn
    if not Core.IsValidObj(pawn) then return nil, nil end
    local okLoc, pLoc = pcall(function() return pawn:K2_GetActorLocation() end)
    if not okLoc or not pLoc then return nil, nil end

    local bestElevObj = nil
    local bestDistSq = math.huge

    local okActors, elevActors = pcall(FindAllOf, "Elevator")
    if okActors and elevActors then
        for _, elevActor in ipairs(elevActors) do
            if Core.IsValidObj(elevActor) then
                local pod = nil
                pcall(function() pod = elevActor.PodActor end)
                if Core.IsValidObj(pod) then
                    local okPodLoc, podLoc = pcall(function() return pod:K2_GetActorLocation() end)
                    if okPodLoc and podLoc then
                        local dx = (pLoc.X or 0.0) - (podLoc.X or 0.0)
                        local dy = (pLoc.Y or 0.0) - (podLoc.Y or 0.0)
                        local dz = (pLoc.Z or 0.0) - (podLoc.Z or 0.0)
                        local xySq = dx * dx + dy * dy
                        if xySq <= POD_MAX_XY_DIST_SQ and dz >= POD_MIN_DZ and dz <= POD_MAX_DZ then
                            local eObj = ExtractElevatorObjectFromActor(elevActor, pod)
                            if Core.IsValidObj(eObj) and xySq < bestDistSq then
                                bestDistSq = xySq
                                bestElevObj = eObj
                            end
                        end
                    end
                end
            end
        end
    end

    if Core.IsValidObj(bestElevObj) then
        return bestElevObj, nil
    end

    -- Fallback: check bottom ElevatorObject instances using actor + GetElevatorPodHeight()
    local okObjs, elevObjs = pcall(FindAllOf, "ElevatorObject")
    if okObjs and elevObjs then
        for _, eObj in ipairs(elevObjs) do
            if Core.IsValidObj(eObj) then
                local isBottom = false
                pcall(function()
                    if eObj.IsBottomElevator then
                        isBottom = (eObj:IsBottomElevator() == true)
                    end
                end)
                if isBottom then
                    local eActor = StationData.GetObjectActor(eObj)
                    if Core.IsValidObj(eActor) then
                        local okELoc, eLoc = pcall(function() return eActor:K2_GetActorLocation() end)
                        if okELoc and eLoc then
                            local podH = 0.0
                            pcall(function()
                                if eObj.GetElevatorPodHeight then
                                    local h = eObj:GetElevatorPodHeight()
                                    if type(h) == "number" then podH = h end
                                end
                            end)
                            local dx = (pLoc.X or 0.0) - (eLoc.X or 0.0)
                            local dy = (pLoc.Y or 0.0) - (eLoc.Y or 0.0)
                            local dz = (pLoc.Z or 0.0) - ((eLoc.Z or 0.0) + podH)
                            local xySq = dx * dx + dy * dy
                            if xySq <= POD_MAX_XY_DIST_SQ and math.abs(dz) <= 320.0 and xySq < bestDistSq then
                                bestDistSq = xySq
                                bestElevObj = eObj
                            end
                        end
                    end
                end
            end
        end
    end

    return bestElevObj, nil
end

local function ExitBuildingModeIfInElevator(pc)
    if not Core.IsValidObj(pc) then
        pc = Core.GetLocalPlayerController()
    end
    if not Core.IsValidObj(pc) then return end

    local elevObj = FindActivePlayerElevator(pc)
    if not Core.IsValidObj(elevObj) then return end

    pcall(function() pc:ExitBuildingMode() end)
    ExecuteInGameThreadWithDelay(1, function()
        if Core.IsValidObj(pc) then
            pcall(function() pc:ExitBuildingMode() end)
        end
    end)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "ElevatorHotkeys_EnterBuildingMode",
        "/Script/MainSequence.DMSPlayerController:EnterBuildingMode",
        function(Context)
            local pc = Context and Context:get() or nil
            ExitBuildingModeIfInElevator(pc)
        end
    )
    Core.TryRegisterHook(
        "ElevatorHotkeys_OnEnterBuildMode",
        "/Game/Blueprints/Player/BP_PlayerController.BP_PlayerController_C:OnEnterBuildMode",
        function(Context)
            local pc = Context and Context:get() or nil
            ExitBuildingModeIfInElevator(pc)
        end
    )
end

local function GoToElevatorFloor(floorNum)
    Feature.RegisterHooks()

    if Core.IsSelectingAnyRegisteredKeybind()
        or Core.IsAnyTextInputFocused()
        or Core.IsAnyWidgetClassVisible("WBP_SettingsMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_PauseMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_MainMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_ElevatorConfig_C")
    then
        return
    end

    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local elevObj, openWidget = FindActivePlayerElevator(pc)
    if not Core.IsValidObj(elevObj) then return end

    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) and Core.IsValidObj(widgetSub.CurrentWindow) then
        if not Core.IsValidObj(openWidget)
            or widgetSub.CurrentWindow:GetAddress() ~= openWidget:GetAddress()
        then
            return
        end
    end

    pcall(function() pc:ExitBuildingMode() end)
    ExecuteInGameThreadWithDelay(1, function()
        if Core.IsValidObj(pc) then
            pcall(function() pc:ExitBuildingMode() end)
        end
    end)

    local bottomElev, stackIdx = ResolveStackIndexForFloor(elevObj, floorNum)
    if not Core.IsValidObj(bottomElev) or stackIdx == nil then return end

    if Core.IsValidObj(openWidget) and openWidget.OnFloorPressed then
        pcall(function() openWidget:OnFloorPressed(stackIdx) end)
        return
    end

    local setConfigCDO = Core.GetCDO(PATHS.SetConfigInputCDO)
    if not Core.IsValidObj(setConfigCDO) then return end

    local okCmd, cmd = pcall(function()
        return setConfigCDO:CreateInputSetConfig(stackIdx, 0)
    end)
    if not okCmd or not Core.IsValidObj(cmd) then
        okCmd, cmd = pcall(function()
            return setConfigCDO:CreateInputSetConfig(stackIdx)
        end)
    end

    if okCmd and Core.IsValidObj(cmd) then
        pcall(function() pc:AddInputCommand(bottomElev.ID, cmd) end)
    end
end

function Feature.OnClientRestart()
    Feature.RegisterHooks()
end

function Feature.Init()
    Feature.RegisterHooks()
    if not Key then return end

    local bindings = {
        { keys = { Key.ONE, Key.NUM_ONE },     floor = 1 },
        { keys = { Key.TWO, Key.NUM_TWO },     floor = 2 },
        { keys = { Key.THREE, Key.NUM_THREE }, floor = 3 },
        { keys = { Key.FOUR, Key.NUM_FOUR },   floor = 4 },
        { keys = { Key.FIVE, Key.NUM_FIVE },   floor = 5 },
        { keys = { Key.SIX, Key.NUM_SIX },     floor = 6 },
        { keys = { Key.SEVEN, Key.NUM_SEVEN }, floor = 7 },
        { keys = { Key.EIGHT, Key.NUM_EIGHT }, floor = 8 },
        { keys = { Key.NINE, Key.NUM_NINE },   floor = 9 },
        { keys = { Key.ZERO, Key.NUM_ZERO },   floor = 10 },
    }

    for _, entry in ipairs(bindings) do
        local floorNum = entry.floor
        for _, keyCode in ipairs(entry.keys) do
            if keyCode ~= nil then
                pcall(RegisterKeyBind, keyCode, function()
                    ExecuteInGameThread(function()
                        GoToElevatorFloor(floorNum)
                    end)
                end)
            end
        end
    end
end

return Feature
