-- Eqol Feature: Elevator Floor Hotkeys
-- Press 1-9 (or 0 for floor 10) while inside an elevator (with or without its UI open)
-- to immediately send the elevator to that floor.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "ElevatorHotkeys",
    DisplayName = "Elevator Floor Hotkeys",
    Description = "Press number keys 1-9 / 0 inside an elevator to jump directly to that floor.",
}

local PATHS = {
    SetConfigInputCDO         = "/Script/MainSequence.Default__SetConfigInput",
    WBPPlayerAlertStatusClass = "/Game/Blueprints/Widgets/HUDs/WBP_PlayerAlertStatus.WBP_PlayerAlertStatus_C",
}

local POD_MAX_XY_DIST_SQ = 240.0 * 240.0
local POD_MIN_DZ = -160.0
local POD_MAX_DZ = 360.0
local ALERT_SCAN_COOLDOWN = 8.0
local NAV_POLL_MS         = 150
local NAV_TIMEOUT_SEC     = 30.0

local CachedElevators = {}      -- addr -> elevActor
local CachedChats = {}          -- addr -> WBP_Chat_C
local CachedAlertWidget = nil
local LastAlertScanTime = -999.0
local LastElevatorScanClock = -10.0
local LastChatScanClock = -10.0
local LastExitBuildClock = -10.0
local LastFloorHotkeyClock = -10.0
local MODIFIER_KEYS = nil
local NavigationToken = 0
local ActiveNavigation = nil    -- { Token, BottomElev, TargetStackIdx, FloorNum, MaxClock }

local function IsAnyModifierKeyDown(pc)
    if not Core.IsValidObj(pc) then return false end
    if MODIFIER_KEYS == nil then
        MODIFIER_KEYS = {}
        for _, kName in ipairs({ "LeftControl", "RightControl", "LeftShift", "RightShift", "LeftAlt", "RightAlt" }) do
            pcall(function() MODIFIER_KEYS[#MODIFIER_KEYS + 1] = { KeyName = FName(kName) } end)
        end
    end
    for _, keyTbl in ipairs(MODIFIER_KEYS) do
        local ok, down = pcall(function() return pc:IsInputKeyDown(keyTbl) end)
        if ok and down == true then
            return true
        end
    end
    return false
end

local function RefreshElevatorCache()
    LastElevatorScanClock = os.clock()
    local nextMap = {}
    local okActors, elevActors = pcall(FindAllOf, "Elevator")
    if okActors and elevActors then
        for _, elevActor in ipairs(elevActors) do
            if Core.IsValidObj(elevActor) then
                nextMap[elevActor:GetAddress()] = elevActor
            end
        end
    end
    CachedElevators = nextMap
end

local function RefreshChatCache()
    LastChatScanClock = os.clock()
    local nextChats = {}
    local okChats, chats = pcall(FindAllOf, "WBP_Chat_C")
    if okChats and chats then
        for _, chat in ipairs(chats) do
            if Core.IsValidObj(chat) then
                nextChats[chat:GetAddress()] = chat
            end
        end
    end
    CachedChats = nextChats
end

local function IsChatOpenFast()
    if os.clock() - LastChatScanClock > 10.0 and next(CachedChats) == nil then
        RefreshChatCache()
    end
    for addr, chat in pairs(CachedChats) do
        if Core.IsValidObj(chat) then
            local okOpen, isOpen = pcall(function() return chat.IsOpen == true end)
            if okOpen and isOpen then
                return true
            end
        else
            CachedChats[addr] = nil
        end
    end
    return false
end

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

local function CheckCachedElevatorsNearPawn(pLoc)
    local bestElevObj = nil
    local bestDistSq = math.huge

    for addr, elevActor in pairs(CachedElevators) do
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
        else
            CachedElevators[addr] = nil
        end
    end

    return bestElevObj
end

local function FindActivePlayerElevator(pc, skipMenuChecks)
    -- Check 1: O(1) check against WidgetSubsystem.CurrentWindow (avoids any FindAllOf scans)
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) and Core.IsValidObj(widgetSub.CurrentWindow) then
        local win = widgetSub.CurrentWindow
        local okCls, winClsName = pcall(function() return win:GetClass():GetFName():ToString() end)
        if okCls and winClsName == "WBP_Elevator_C" then
            local okVis, isVis = pcall(function() return win:IsVisible() end)
            if okVis and isVis and Core.IsValidObj(win.ElevatorObject) then
                return win.ElevatorObject, win
            end
        end
        -- Another native UI window owns input (Settings, Pause, Rename, ElevatorConfig, Codex, etc.)
        return nil, nil
    end

    -- Check 2: Player standing inside an elevator pod in normal gameplay
    if not skipMenuChecks then
        local showCursor = false
        pcall(function() showCursor = (pc.bShowMouseCursor == true) end)
        if showCursor then return nil, nil end
    end

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

    local bestElevObj = CheckCachedElevatorsNearPawn(pLoc)
    if Core.IsValidObj(bestElevObj) then
        return bestElevObj, nil
    end

    -- Refresh cache only if we missed and cooldown expired (e.g. newly built elevator)
    if os.clock() - LastElevatorScanClock >= 1.5 then
        RefreshElevatorCache()
        bestElevObj = CheckCachedElevatorsNearPawn(pLoc)
        if Core.IsValidObj(bestElevObj) then
            return bestElevObj, nil
        end
    end

    return nil, nil
end

local function ExitBuildingModeIfInElevator(pc)
    local now = os.clock()
    -- Only suppress build mode immediately after an elevator floor hotkey press (within 150ms),
    -- so intentional building near an elevator pod is never blocked.
    if (now - LastFloorHotkeyClock) > 0.15 then return end
    if now - LastExitBuildClock < 0.03 then return end
    if not Core.IsValidObj(pc) then
        pc = Core.GetLocalPlayerController()
    end
    if not Core.IsValidObj(pc) then return end

    LastExitBuildClock = now
    pcall(function() pc:ExitBuildingMode() end)
    ExecuteInGameThreadWithDelay(1, function()
        if Core.IsValidObj(pc) then
            pcall(function() pc:ExitBuildingMode() end)
        end
    end)
end

Feature.WatchWidgets = {
    WBP_Chat_C = function(chat)
        if Core.IsValidObj(chat) then
            CachedChats[chat:GetAddress()] = chat
        end
    end,
    WBP_PlayerAlerts_C = function(w)
        if Core.IsValidObj(w) then
            CachedAlertWidget = w
        end
    end,
}

local function ClearActiveNavigation()
    NavigationToken = NavigationToken + 1
    ActiveNavigation = nil
end

local function PushElevatorAlert(messageStr)
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end

    local targetWidget = nil
    if Core.IsValidObj(CachedAlertWidget) and Core.IsValidObj(CachedAlertWidget.Container) then
        targetWidget = CachedAlertWidget
    else
        CachedAlertWidget = nil
        local now = os.clock()
        if (now - LastAlertScanTime) >= ALERT_SCAN_COOLDOWN then
            LastAlertScanTime = now
            local okAlerts, found = pcall(FindAllOf, "WBP_PlayerAlerts_C")
            if okAlerts and found and #found > 0 then
                local fallback = nil
                for _, w in ipairs(found) do
                    if Core.IsValidObj(w) and Core.IsValidObj(w.Container) then
                        if not fallback then fallback = w end
                        local okVP, inVP = pcall(function() return w:IsInViewport() end)
                        local okVis, isVis = pcall(function() return w:IsVisible() end)
                        if (okVP and inVP) or (okVis and isVis) then
                            targetWidget = w
                            break
                        end
                    end
                end
                targetWidget = targetWidget or fallback
                if Core.IsValidObj(targetWidget) then
                    CachedAlertWidget = targetWidget
                end
            end
        end
    end
    if not Core.IsValidObj(targetWidget) or not Core.IsValidObj(targetWidget.Container) then
        return false
    end

    local pushed = false
    local entryW = Core.CreateUserWidget(PATHS.WBPPlayerAlertStatusClass, targetWidget, pc)
    if Core.IsValidObj(entryW) then
        pcall(function()
            if Core.IsValidObj(entryW.WBP_RichText) then
                entryW.WBP_RichText:SetText(Core.MakeText(tostring(messageStr or "")))
            end
            if targetWidget.Container.AddChildToVerticalBox then
                targetWidget.Container:AddChildToVerticalBox(entryW)
            else
                targetWidget.Container:AddChild(entryW)
            end
            pushed = true
        end)
        ExecuteInGameThreadWithDelay(3000, function()
            if Core.IsValidObj(entryW) then
                pcall(function()
                    if entryW.RemoveSelf then
                        entryW:RemoveSelf()
                    elseif entryW.RemoveFromParent then
                        entryW:RemoveFromParent()
                    end
                end)
            end
        end)
    end
    return pushed
end

local function IsElevatorAtTargetIdle(bottomElev, targetStackIdx)
    if not Core.IsValidObj(bottomElev) then return true end
    local curF = nil
    local isMoving = false
    pcall(function()
        curF = tonumber(bottomElev.CurrentFloor)
        isMoving = (bottomElev.bMoving == true)
    end)
    return (curF == targetStackIdx and not isMoving)
end

-- Locks further elevator floor hotkey presses until the elevator arrives at targetStackIdx
-- (or hits the safety timeout / map reload). Never mutates simulation state directly.
local function BeginElevatorNavigationLock(bottomElev, targetStackIdx, floorNum)
    NavigationToken = NavigationToken + 1
    local myToken = NavigationToken
    local nav = {
        Token = myToken,
        BottomElev = bottomElev,
        TargetStackIdx = targetStackIdx,
        FloorNum = floorNum,
        MaxClock = os.clock() + NAV_TIMEOUT_SEC,
    }
    ActiveNavigation = nav

    local function PollArrival()
        if myToken ~= NavigationToken or ActiveNavigation ~= nav then return end
        if not Core.IsValidObj(bottomElev) or os.clock() > nav.MaxClock then
            ClearActiveNavigation()
            return
        end
        if IsElevatorAtTargetIdle(bottomElev, targetStackIdx) then
            ClearActiveNavigation()
            return
        end
        ExecuteInGameThreadWithDelay(NAV_POLL_MS, PollArrival)
    end

    ExecuteInGameThreadWithDelay(NAV_POLL_MS, PollArrival)
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
    if Core.IsSelectingAnyRegisteredKeybind() or Core.IsAnyTextInputFocused() or IsChatOpenFast() then
        return
    end

    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end
    if IsAnyModifierKeyDown(pc) then return end

    -- Block further floor hotkey selections while a hotkey-initiated elevator trip is in progress
    if ActiveNavigation then
        if Core.IsValidObj(ActiveNavigation.BottomElev) and os.clock() <= ActiveNavigation.MaxClock then
            if IsElevatorAtTargetIdle(ActiveNavigation.BottomElev, ActiveNavigation.TargetStackIdx) then
                ClearActiveNavigation()
            else
                return
            end
        else
            ClearActiveNavigation()
        end
    end

    local elevObj, openWidget = FindActivePlayerElevator(pc, false)
    if not Core.IsValidObj(elevObj) then return end

    local bottomElev, stackIdx = ResolveStackIndexForFloor(elevObj, floorNum)
    if not Core.IsValidObj(bottomElev) or stackIdx == nil then return end

    LastFloorHotkeyClock = os.clock()

    local curFloor = nil
    pcall(function() curFloor = tonumber(bottomElev.CurrentFloor) end)

    local sentCommand = false
    if Core.IsValidObj(openWidget) and openWidget.OnFloorPressed then
        local okCall = pcall(function() openWidget:OnFloorPressed(stackIdx) end)
        sentCommand = okCall == true
    else
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
            local okAdd = pcall(function() pc:AddInputCommand(bottomElev.ID, cmd) end)
            sentCommand = okAdd == true
        end
    end

    if sentCommand and curFloor ~= stackIdx then
        PushElevatorAlert(string.format("Navigating to Floor %d", floorNum))
        BeginElevatorNavigationLock(bottomElev, stackIdx, floorNum)
        Core.Log(string.format("[ElevatorHotkeys] GoToFloor=%s stackIdx=%s curFloor=%s",
            tostring(floorNum), tostring(stackIdx), tostring(curFloor)))
    end

    LastExitBuildClock = os.clock()
    pcall(function() pc:ExitBuildingMode() end)
    ExecuteInGameThreadWithDelay(1, function()
        if Core.IsValidObj(pc) then
            pcall(function() pc:ExitBuildingMode() end)
        end
    end)
end

function Feature.OnToggle(enabled)
    if not enabled then
        ClearActiveNavigation()
    end
end

function Feature.OnClientRestart()
    ClearActiveNavigation()
    Feature.RegisterHooks()
    ExecuteInGameThreadWithDelay(300, function()
        RefreshElevatorCache()
        RefreshChatCache()
    end)
end

function Feature.OnMapLoad()
    ClearActiveNavigation()
    CachedAlertWidget = nil
    LastAlertScanTime = -999.0
    Feature.RegisterHooks()
    ExecuteInGameThreadWithDelay(300, function()
        RefreshElevatorCache()
        RefreshChatCache()
    end)
end

function Feature.PruneCaches()
    for addr, actor in pairs(CachedElevators) do
        if not Core.IsValidObj(actor) then
            CachedElevators[addr] = nil
        end
    end
    for addr, chat in pairs(CachedChats) do
        if not Core.IsValidObj(chat) then
            CachedChats[addr] = nil
        end
    end
    if CachedAlertWidget and not Core.IsValidObj(CachedAlertWidget) then
        CachedAlertWidget = nil
    end
end

function Feature.Init()
    Feature.RegisterHooks()
    ExecuteInGameThreadWithDelay(300, function()
        RefreshElevatorCache()
        RefreshChatCache()
    end)
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
                    if not Core.IsFeatureEnabled("ElevatorHotkeys") then return end
                    ExecuteInGameThread(function()
                        GoToElevatorFloor(floorNum)
                    end)
                end)
            end
        end
    end
end

return Feature
