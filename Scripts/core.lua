-- Eqol (Elvenide's Quality of Life) - Core Utilities & Feature Registry
-- 100% client-side / save-safe: does not modify world saves, pak files, or serialized objects.

local UEHelpers = require("UEHelpers")

local Core = {}

Core.PATHS = {
    PlayerControllerClass = "/Game/Blueprints/Player/BP_PlayerController.BP_PlayerController_C",
    WidgetSubsystemClass  = "/Script/MainSequence.WidgetSubsystem",
    WorldSubsystemClass   = "/Script/MainSequence.DMSWorldSubsystem",
    SubsystemLibCDO       = "/Script/Engine.Default__SubsystemBlueprintLibrary",
    WidgetBlueprintLibCDO = "/Script/UMG.Default__WidgetBlueprintLibrary",
    WidgetLayoutLibCDO    = "/Script/UMG.Default__WidgetLayoutLibrary",
    KismetTextLibCDO      = "/Script/Engine.Default__KismetTextLibrary",
    EnhancedInputLibCDO   = "/Script/EnhancedInput.Default__EnhancedInputLibrary",
    FPMathCDO             = "/Script/MainSequence.Default__FPMath",
    VerticalBoxClass      = "/Script/UMG.VerticalBox",
    HorizontalBoxClass    = "/Script/UMG.HorizontalBox",
    SizeBoxClass          = "/Script/UMG.SizeBox",
}

Core.Config = {}

local RegisteredHookAddresses = {}
local Features = {}
local WatchedWidgetClasses = {}

function Core.Log(msg)
    print(string.format("[Eqol] %s\n", tostring(msg)))
end

function Core.IsValidObj(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function()
        return type(obj.IsValid) == "function" and obj:IsValid()
    end)
    return ok and valid == true
end

function Core.UnwrapArrayElem(elem)
    if elem == nil then return nil end
    if Core.IsValidObj(elem) then return elem end
    local ok, val = pcall(function() return elem:get() end)
    if ok and Core.IsValidObj(val) then return val end
    return nil
end

function Core.Clamp(val, lo, hi)
    if val < lo then return lo end
    if val > hi then return hi end
    return val
end

function Core.FindOrLoadClass(path)
    local cls = StaticFindObject(path)
    if Core.IsValidObj(cls) then return cls end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and Core.IsValidObj(loaded) then return loaded end
    return StaticFindObject(path)
end

function Core.GetCDO(path)
    return StaticFindObject(path)
end

function Core.GetFPFloat(fpNum)
    if not fpNum then return 0.0 end
    if type(fpNum) == "number" then return fpNum end
    if type(fpNum) ~= "userdata" then return 0.0 end
    local okUObj, isUObj = pcall(function() return type(fpNum.IsValid) == "function" end)
    if okUObj and isUObj then return 0.0 end

    local fpMath = Core.GetCDO(Core.PATHS.FPMathCDO)
    if Core.IsValidObj(fpMath) then
        local ok, val = pcall(function() return fpMath:GetFloat(fpNum) end)
        if ok and type(val) == "number" then
            return val
        end
    end
    return 0.0
end

function Core.GetFPVector(fpVec)
    if not fpVec then return 0.0, 0.0, 0.0 end
    if type(fpVec.X) == "number" and type(fpVec.Y) == "number" then
        return fpVec.X, fpVec.Y, tonumber(fpVec.Z) or 0.0
    end
    if type(fpVec) ~= "userdata" then return 0.0, 0.0, 0.0 end
    local okUObj, isUObj = pcall(function() return type(fpVec.IsValid) == "function" end)
    if okUObj and isUObj then return 0.0, 0.0, 0.0 end

    local fpMath = Core.GetCDO(Core.PATHS.FPMathCDO)
    if Core.IsValidObj(fpMath) then
        local ok, vec = pcall(function() return fpMath:GetVector(fpVec) end)
        if ok and vec and type(vec.X) == "number" then
            return vec.X, vec.Y, tonumber(vec.Z) or 0.0
        end
    end
    return 0.0, 0.0, 0.0
end

function Core.MakeText(str)
    local ktl = Core.GetCDO(Core.PATHS.KismetTextLibCDO)
    if Core.IsValidObj(ktl) then
        local ok, txt = pcall(function() return ktl:Conv_StringToText(str) end)
        if ok and txt then return txt end
    end
    return FText(str)
end

function Core.GetModDir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    local modDir = src:match("^(.*)[/\\]Scripts[/\\][^/\\]+$")
    return (modDir and modDir ~= "") and modDir or "."
end

function Core.GetConfigPath()
    return Core.GetModDir() .. "/config.json"
end

function Core.WriteConfig()
    local path = Core.GetConfigPath()
    local f = io.open(path, "w")
    if not f then
        Core.Log("Warning: could not write config file at " .. path)
        return
    end

    local keys = {}
    for k in pairs(Core.Config) do
        table.insert(keys, k)
    end
    table.sort(keys)

    local lines = { "{" }
    for idx, k in ipairs(keys) do
        local v = Core.Config[k]
        local safeKey = tostring(k):gsub('[\\"]', "")
        local serialized
        if type(v) == "boolean" then
            serialized = v and "true" or "false"
        elseif type(v) == "number" then
            serialized = tostring(v)
        else
            serialized = string.format('"%s"', tostring(v):gsub('[\\"]', ""))
        end
        local comma = (idx < #keys) and "," or ""
        table.insert(lines, string.format('    "%s": %s%s', safeKey, serialized, comma))
    end
    table.insert(lines, "}")

    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
end

function Core.ReadConfig(defaults)
    if defaults then
        for k, v in pairs(defaults) do
            if Core.Config[k] == nil then
                Core.Config[k] = v
            end
        end
    end

    local path = Core.GetConfigPath()
    local f = io.open(path, "r")
    if not f then
        Core.WriteConfig()
        return
    end
    local raw = f:read("*a") or ""
    f:close()

    local dirty = false
    for k, defaultVal in pairs(Core.Config) do
        if type(defaultVal) == "boolean" then
            local bVal = raw:match('"' .. k .. '"%s*:%s*(true|false)')
            if bVal == "true" then
                Core.Config[k] = true
            elseif bVal == "false" then
                Core.Config[k] = false
            else
                dirty = true
            end
        elseif type(defaultVal) == "number" then
            local nVal = raw:match('"' .. k .. '"%s*:%s*(-?%d+%.?%d*)')
            if nVal and tonumber(nVal) then
                Core.Config[k] = tonumber(nVal)
            else
                dirty = true
            end
        else
            local sVal = raw:match('"' .. k .. '"%s*:%s*"([^"]*)"')
            if sVal and sVal ~= "" then
                Core.Config[k] = sVal
            else
                dirty = true
            end
        end
    end

    if dirty then
        Core.WriteConfig()
    end
end

local CachedLocalPC = nil

function Core.GetLocalPlayerController()
    if Core.IsValidObj(CachedLocalPC) then
        local okLocal, isLocal = pcall(function() return CachedLocalPC:IsLocalPlayerController() end)
        if okLocal and isLocal then
            return CachedLocalPC
        end
        CachedLocalPC = nil
    end

    local ok, list = pcall(FindAllOf, "BP_PlayerController_C")
    if ok and list then
        for _, pc in ipairs(list) do
            if Core.IsValidObj(pc) then
                local okLocal, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
                if okLocal and isLocal then
                    CachedLocalPC = pc
                    return pc
                end
            end
        end
    end
    local fallback = UEHelpers.GetPlayerController()
    if Core.IsValidObj(fallback) then
        local okLocal, isLocal = pcall(function() return fallback:IsLocalPlayerController() end)
        if okLocal and isLocal then
            CachedLocalPC = fallback
            return fallback
        end
    end
    return nil
end

function Core.GetWorldSubsystem(worldContext, classPath)
    local subLib = Core.GetCDO(Core.PATHS.SubsystemLibCDO)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(subLib) or not Core.IsValidObj(cls) or not Core.IsValidObj(worldContext) then
        return nil
    end
    local ok, sub = pcall(function() return subLib:GetWorldSubsystem(worldContext, cls) end)
    if ok and Core.IsValidObj(sub) then
        return sub
    end
    return nil
end

function Core.IsAnyWidgetClassVisible(shortClassName)
    local ok, widgets = pcall(FindAllOf, shortClassName)
    if not ok or not widgets then return false end
    for _, w in ipairs(widgets) do
        if Core.IsValidObj(w) then
            local okInVp, inVp = pcall(function() return w:IsInViewport() end)
            local okVis, vis = pcall(function() return w:IsVisible() end)
            if okInVp and inVp and okVis and vis then
                return true
            end
        end
    end
    return false
end

function Core.CreateRawWidget(classPath, outer)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(cls) or not Core.IsValidObj(outer) then return nil end
    local ok, widget = pcall(StaticConstructObject, cls, outer)
    if ok and Core.IsValidObj(widget) then return widget end
    return nil
end

function Core.CreateUserWidget(classPath, worldContext, owningPC)
    local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(wbl) or not Core.IsValidObj(cls) or not Core.IsValidObj(worldContext) then
        return nil
    end
    local ok, widget = pcall(function() return wbl:Create(worldContext, cls, owningPC) end)
    if ok and Core.IsValidObj(widget) then
        return widget
    end
    return nil
end

function Core.GetWidgetOuter(parentWidget)
    if Core.IsValidObj(parentWidget.WidgetTree) then
        return parentWidget.WidgetTree
    end
    return parentWidget
end

function Core.TryRegisterHook(hookKey, ufuncPath, callbackFn)
    local ufunc = StaticFindObject(ufuncPath)
    if not Core.IsValidObj(ufunc) then return false end

    local addr = ufunc:GetAddress()
    if RegisteredHookAddresses[hookKey] == addr then
        return true
    end

    local ok = pcall(RegisterHook, ufuncPath, callbackFn)
    if ok then
        RegisteredHookAddresses[hookKey] = addr
        return true
    end
    return false
end

function Core.RegisterFeature(feature)
    if type(feature) ~= "table" then return end
    table.insert(Features, feature)
    if type(feature.WatchWidgets) == "table" then
        for clsName, handler in pairs(feature.WatchWidgets) do
            WatchedWidgetClasses[clsName] = WatchedWidgetClasses[clsName] or {}
            table.insert(WatchedWidgetClasses[clsName], handler)
        end
    end
end

function Core.InitAll()
    for _, feature in ipairs(Features) do
        if type(feature.Init) == "function" then
            feature.Init(Core)
        end
    end
end

function Core.SpawnActor(worldContext, classPath, loc, rot)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(cls) then
        Core.Log("Core.SpawnActor: failed to find/load class " .. tostring(classPath))
        return nil
    end

    local world = nil
    if Core.IsValidObj(worldContext) and worldContext.GetWorld then
        pcall(function() world = worldContext:GetWorld() end)
    end
    if not Core.IsValidObj(world) and UEHelpers and UEHelpers.GetWorld then
        pcall(function() world = UEHelpers.GetWorld() end)
    end
    if not Core.IsValidObj(world) then
        Core.Log("Core.SpawnActor: no valid UWorld")
        return nil
    end

    local pos = loc or { X = 0.0, Y = 0.0, Z = 0.0 }
    local ang = rot or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    local ok, actor = pcall(function() return world:SpawnActor(cls, pos, ang) end)
    if ok and Core.IsValidObj(actor) then
        return actor
    end
    Core.Log("Core.SpawnActor: SpawnActor failed for " .. tostring(classPath))
    return nil
end

function Core.EnsureAllHooks()
    Core.EnsureKeybindHooks()
    for _, feature in ipairs(Features) do
        if type(feature.RegisterHooks) == "function" then
            feature.RegisterHooks(Core)
        end
    end
end

local TrackedTextInputs = {} -- widgetAddr -> { Input = widget, Owner = ownerWindowOrNil }
local TextInputFocusWatcherActive = false
local SuppressedCharacterInput = false
local SuppressedCharacterInputPC = nil

local function IsWidgetTreeVisible(w, ownerWin)
    if not Core.IsValidObj(w) then return false end
    if Core.IsValidObj(ownerWin) then
        local okVP, inVp = pcall(function()
            return not ownerWin.IsInViewport or ownerWin:IsInViewport()
        end)
        if okVP and not inVp then return false end
        local okOV, oVis = pcall(function() return ownerWin:IsVisible() end)
        if okOV and not oVis then return false end
    end
    local cur = w
    for _ = 1, 20 do
        if not Core.IsValidObj(cur) then break end
        local okV, vis = pcall(function() return cur:IsVisible() end)
        if okV and not vis then
            return false
        end
        local okP, parent = pcall(function() return cur:GetParent() end)
        if not okP or not Core.IsValidObj(parent) then
            break
        end
        cur = parent
    end
    return true
end

local function IsWidgetOrChildFocused(w, pc)
    if not Core.IsValidObj(w) then return false end
    for _, checkName in ipairs({ "HasKeyboardFocus", "HasAnyUserFocus", "HasFocusedDescendants" }) do
        local ok, res = pcall(function()
            return w[checkName] and w[checkName](w)
        end)
        if ok and res == true then
            return true
        end
    end
    if Core.IsValidObj(pc) then
        local okU, resU = pcall(function()
            return w.HasUserFocus and w:HasUserFocus(pc)
        end)
        if okU and resU == true then
            return true
        end
    end
    return false
end

local function IsTrackedInputFocused(entry, pc)
    local w = entry and entry.Input or nil
    if not Core.IsValidObj(w) then return false end
    if not IsWidgetTreeVisible(w, entry.Owner) then return false end

    if IsWidgetOrChildFocused(w, pc) then return true end
    local okBox, box = pcall(function() return w.EditableTextBox_80 end)
    if okBox and Core.IsValidObj(box) and IsWidgetOrChildFocused(box, pc) then
        return true
    end
    return false
end

local function IsAnyTrackedTextInputFocused()
    local pc = Core.GetLocalPlayerController()
    for addr, entry in pairs(TrackedTextInputs) do
        if not Core.IsValidObj(entry.Input) then
            TrackedTextInputs[addr] = nil
        elseif IsTrackedInputFocused(entry, pc) then
            return true
        end
    end
    return false
end

local function RestoreSuppressedCharacterInput()
    if not SuppressedCharacterInput then return end
    local pc = Core.IsValidObj(SuppressedCharacterInputPC) and SuppressedCharacterInputPC or Core.GetLocalPlayerController()
    if Core.IsValidObj(pc) then
        pcall(function() pc:AllowCharacterInput(true) end)
    end
    SuppressedCharacterInput = false
    SuppressedCharacterInputPC = nil
end

local function SyncCharacterInputSuppression()
    local anyFocused = IsAnyTrackedTextInputFocused()
    local pc = Core.GetLocalPlayerController()
    if anyFocused then
        if Core.IsValidObj(pc) and pc.CharacterInputEnabled == true then
            pcall(function() pc:AllowCharacterInput(false) end)
            SuppressedCharacterInput = true
            SuppressedCharacterInputPC = pc
        end
    else
        RestoreSuppressedCharacterInput()
    end
    return anyFocused
end

local function EnsureTextInputFocusWatcher()
    if TextInputFocusWatcherActive then return end
    TextInputFocusWatcherActive = true

    local function WatcherTick()
        if next(TrackedTextInputs) == nil then
            RestoreSuppressedCharacterInput()
            TextInputFocusWatcherActive = false
            return
        end

        local anyVisible = false
        for addr, entry in pairs(TrackedTextInputs) do
            if not Core.IsValidObj(entry.Input) then
                TrackedTextInputs[addr] = nil
            elseif IsWidgetTreeVisible(entry.Input, entry.Owner) then
                anyVisible = true
            end
        end

        SyncCharacterInputSuppression()
        ExecuteInGameThreadWithDelay(anyVisible and 25 or 200, WatcherTick)
    end

    ExecuteInGameThreadWithDelay(25, WatcherTick)
end

function Core.RegisterTextInput(textInputWidget, ownerWindow)
    if not Core.IsValidObj(textInputWidget) then return end
    TrackedTextInputs[textInputWidget:GetAddress()] = {
        Input = textInputWidget,
        Owner = Core.IsValidObj(ownerWindow) and ownerWindow or nil,
    }
    Core.EnsureKeybindHooks()
    EnsureTextInputFocusWatcher()
end

function Core.IsAnyTextInputFocused()
    if IsAnyTrackedTextInputFocused() then
        return true
    end
    if Core.IsAnyWidgetClassVisible("WBP_RenamePopup_C")
        or Core.IsAnyWidgetClassVisible("WBP_ElevatorConfig_C")
    then
        return true
    end
    local okChats, chats = pcall(FindAllOf, "WBP_Chat_C")
    if okChats and chats then
        for _, chat in ipairs(chats) do
            if Core.IsValidObj(chat) then
                local okOpen, isOpen = pcall(function() return chat.IsOpen == true end)
                if okOpen and isOpen then
                    return true
                end
            end
        end
    end
    return false
end

function Core.PruneAllCaches()
    for addr, entry in pairs(TrackedTextInputs) do
        if not Core.IsValidObj(entry.Input) then
            TrackedTextInputs[addr] = nil
        end
    end
    SuppressedCharacterInput = false
    SuppressedCharacterInputPC = nil
    for _, feature in ipairs(Features) do
        if type(feature.PruneCaches) == "function" then
            feature.PruneCaches(Core)
        end
    end
end

function Core.DispatchClientRestart()
    Core.PruneAllCaches()
    Core.EnsureAllHooks()
    for _, feature in ipairs(Features) do
        if type(feature.OnClientRestart) == "function" then
            feature.OnClientRestart(Core)
        end
    end
end

function Core.DispatchMapLoad()
    Core.PruneAllCaches()
    Core.EnsureAllHooks()
    for _, feature in ipairs(Features) do
        if type(feature.OnMapLoad) == "function" then
            feature.OnMapLoad(Core)
        end
    end
end

function Core.IsWatchedWidgetClass(clsName)
    return WatchedWidgetClasses[clsName] ~= nil
end

function Core.DispatchWidgetConstructed(widget, clsName)
    local handlers = WatchedWidgetClasses[clsName]
    if not handlers then return end
    for _, handler in ipairs(handlers) do
        handler(widget, Core)
    end
end

--------------------------------------------------------------------------------
-- Reusable Configurable Keybind & Settings -> Controls Row Helper
--------------------------------------------------------------------------------

local UE_TO_UE4SS_KEY = {
    BackSpace         = Key and Key.BACKSPACE,
    Tab               = Key and Key.TAB,
    Enter             = Key and Key.RETURN,
    Return            = Key and Key.RETURN,
    Pause             = Key and Key.PAUSE,
    CapsLock          = Key and Key.CAPS_LOCK,
    Escape            = Key and Key.ESCAPE,
    SpaceBar          = Key and Key.SPACE,
    PageUp            = Key and Key.PAGE_UP,
    PageDown          = Key and Key.PAGE_DOWN,
    End               = Key and Key.END,
    Home              = Key and Key.HOME,
    Left              = Key and Key.LEFT_ARROW,
    Up                = Key and Key.UP_ARROW,
    Right             = Key and Key.RIGHT_ARROW,
    Down              = Key and Key.DOWN_ARROW,
    Insert            = Key and Key.INS,
    Delete            = Key and Key.DEL,
    Zero              = Key and Key.ZERO,
    One               = Key and Key.ONE,
    Two               = Key and Key.TWO,
    Three             = Key and Key.THREE,
    Four              = Key and Key.FOUR,
    Five              = Key and Key.FIVE,
    Six               = Key and Key.SIX,
    Seven             = Key and Key.SEVEN,
    Eight             = Key and Key.EIGHT,
    Nine              = Key and Key.NINE,
    NumPadZero        = Key and Key.NUM_ZERO,
    NumPadOne         = Key and Key.NUM_ONE,
    NumPadTwo         = Key and Key.NUM_TWO,
    NumPadThree       = Key and Key.NUM_THREE,
    NumPadFour        = Key and Key.NUM_FOUR,
    NumPadFive        = Key and Key.NUM_FIVE,
    NumPadSix         = Key and Key.NUM_SIX,
    NumPadSeven       = Key and Key.NUM_SEVEN,
    NumPadEight       = Key and Key.NUM_EIGHT,
    NumPadNine        = Key and Key.NUM_NINE,
    Semicolon         = Key and Key.OEM_ONE,
    Equals            = Key and Key.OEM_PLUS,
    Comma             = Key and Key.OEM_COMMA,
    Hyphen            = Key and Key.OEM_MINUS,
    Period            = Key and Key.OEM_PERIOD,
    Slash             = Key and Key.OEM_TWO,
    Tilde             = Key and Key.OEM_THREE,
    LeftBracket       = Key and Key.OEM_FOUR,
    Backslash         = Key and Key.OEM_FIVE,
    RightBracket      = Key and Key.OEM_SIX,
    Apostrophe        = Key and Key.OEM_SEVEN,
}

local RegisteredKeybinds = {}   -- mappingName -> bindingState
local SharedKeyHandlers = {}    -- ue4ssKey -> true
local SharedRemapHooksDone = false

local function ResolveUE4SSKey(keyName)
    if not keyName or keyName == "" or keyName == "None" or not Key then return nil end
    if UE_TO_UE4SS_KEY[keyName] then return UE_TO_UE4SS_KEY[keyName] end
    local upper = string.upper(keyName)
    return Key[upper]
end

local function MakeInputChord(keyName)
    local resolvedName = (keyName and keyName ~= "") and keyName or "None"
    return {
        Key = { KeyName = FName(resolvedName) },
        bShift = false,
        bCtrl = false,
        bAlt = false,
        bCmd = false,
    }
end

function Core.IsSelectingAnyRegisteredKeybind()
    for _, bs in pairs(RegisteredKeybinds) do
        for addr, row in pairs(bs.TrackedRows) do
            if Core.IsValidObj(row) then
                local sel = row.InputKeySelector
                if Core.IsValidObj(sel) then
                    local okS, selecting = pcall(function() return sel:GetIsSelectingKey() end)
                    if okS and selecting then return true end
                end
            else
                bs.TrackedRows[addr] = nil
            end
        end
    end
    return false
end

local function SyncKeybindRow(bs, row)
    if not Core.IsValidObj(row) then return end
    row.MappingName = FName(bs.MappingName)
    local lbl = Core.MakeText(bs.Label)
    row.InputActionText = lbl
    if Core.IsValidObj(row.WBP_SettingEntryBody) then
        pcall(function() row.WBP_SettingEntryBody:SetText(lbl) end)
    end
    if Core.IsValidObj(row.InputKeySelector) then
        pcall(function() row.InputKeySelector:SetSelectedKey(MakeInputChord(Core.Config[bs.ConfigKey])) end)
    end
end

local function ApplyKeybindState(bs, keyName, shouldSave)
    local normalized = (keyName and keyName ~= "") and keyName or "None"
    Core.Config[bs.ConfigKey] = normalized
    if shouldSave then Core.WriteConfig() end
    if type(bs.OnChanged) == "function" then
        pcall(bs.OnChanged, normalized)
    end

    local ue4ssKey = ResolveUE4SSKey(normalized)
    bs.ActiveUe4ssKey = ue4ssKey
    bs.FallbackWasDown = false

    if ue4ssKey ~= nil then
        if not SharedKeyHandlers[ue4ssKey] then
            SharedKeyHandlers[ue4ssKey] = true
            RegisterKeyBind(ue4ssKey, function()
                for _, entry in pairs(RegisteredKeybinds) do
                    if entry.ActiveUe4ssKey == ue4ssKey then
                        ExecuteInGameThread(function()
                            if not Core.IsSelectingAnyRegisteredKeybind()
                                and not Core.IsAnyTextInputFocused()
                                and not Core.IsAnyWidgetClassVisible("WBP_SettingsMenu_C")
                                and not Core.IsAnyWidgetClassVisible("WBP_PauseMenu_C")
                                and not Core.IsAnyWidgetClassVisible("WBP_MainMenu_C")
                            then
                                entry.OnPress()
                            end
                        end)
                    end
                end
            end)
        end
    elseif not bs.FallbackPollActive and normalized ~= "None" then
        bs.FallbackPollActive = true
        local function PollTick()
            local cur = Core.Config[bs.ConfigKey]
            if bs.ActiveUe4ssKey ~= nil or cur == "None" or cur == "" then
                bs.FallbackPollActive = false
                return
            end
            local pc = Core.GetLocalPlayerController()
            if Core.IsValidObj(pc) then
                local okD, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(cur) }) end)
                if okD and down and not bs.FallbackWasDown then
                    bs.FallbackWasDown = true
                    if not Core.IsSelectingAnyRegisteredKeybind()
                        and not Core.IsAnyTextInputFocused()
                        and not Core.IsAnyWidgetClassVisible("WBP_SettingsMenu_C")
                        and not Core.IsAnyWidgetClassVisible("WBP_PauseMenu_C")
                        and not Core.IsAnyWidgetClassVisible("WBP_MainMenu_C")
                    then
                        bs.OnPress()
                    end
                elseif not okD or not down then
                    bs.FallbackWasDown = false
                end
            end
            ExecuteInGameThreadWithDelay(33, PollTick)
        end
        ExecuteInGameThreadWithDelay(33, PollTick)
    end
end

local function EnsureMenuKeybindRows(menu)
    if not Core.IsValidObj(menu) then return end
    local scrollBox = menu.ControlSettings
    if not Core.IsValidObj(scrollBox) then return end
    local menuAddr = menu:GetAddress()
    local pc = Core.IsValidObj(menu.PC) and menu.PC or Core.GetLocalPlayerController()

    for _, bs in pairs(RegisteredKeybinds) do
        local existing = bs.MenuRows[menuAddr]
        if Core.IsValidObj(existing) then
            local okHas, hasChild = pcall(function() return scrollBox:HasChild(existing) end)
            if okHas and hasChild then
                SyncKeybindRow(bs, existing)
                goto continue_kb
            end
        end

        local row = Core.CreateUserWidget("/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C", menu, pc)
        if Core.IsValidObj(row) then
            bs.MenuRows[menuAddr] = row
            bs.TrackedRows[row:GetAddress()] = row
            row.MappingName = FName(bs.MappingName)
            local slot = scrollBox:AddChild(row)
            if Core.IsValidObj(slot) then
                local refRow = Core.IsValidObj(menu.StatusWindow) and menu.StatusWindow or menu.Statistics
                if Core.IsValidObj(refRow) and Core.IsValidObj(refRow.Slot) then
                    pcall(function()
                        slot:SetPadding(refRow.Slot.Padding)
                        slot:SetHorizontalAlignment(refRow.Slot.HorizontalAlignment)
                        slot:SetVerticalAlignment(refRow.Slot.VerticalAlignment)
                    end)
                end
            end
            SyncKeybindRow(bs, row)
        end
        ::continue_kb::
    end
end

function Core.EnsureKeybindHooks()
    if not SharedRemapHooksDone then
        SharedRemapHooksDone = true
        WatchedWidgetClasses["WBP_SettingsMenu_C"] = WatchedWidgetClasses["WBP_SettingsMenu_C"] or {}
        table.insert(WatchedWidgetClasses["WBP_SettingsMenu_C"], function(menu)
            Core.EnsureKeybindHooks()
            EnsureMenuKeybindRows(menu)
        end)
    end

    Core.TryRegisterHook(
        "Core_SettingsMenu_Setup",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Setup",
        function(Context)
            local menu = Context:get()
            ExecuteInGameThreadWithDelay(1, function()
                if Core.IsValidObj(menu) then EnsureMenuKeybindRows(menu) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_SettingsMenu_Refresh",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Refresh",
        function(Context)
            local menu = Context:get()
            ExecuteInGameThreadWithDelay(1, function()
                if Core.IsValidObj(menu) then EnsureMenuKeybindRows(menu) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_SettingsMenu_RefreshInGame",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:RefreshInGame",
        function(Context)
            local menu = Context:get()
            ExecuteInGameThreadWithDelay(1, function()
                if Core.IsValidObj(menu) then EnsureMenuKeybindRows(menu) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_LoadSettings",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:LoadSettings",
        function(Context)
            local row = Context:get()
            ExecuteInGameThread(function()
                if not Core.IsValidObj(row) then return end
                local okN, mName = pcall(function() return row.MappingName:ToString() end)
                local bs = okN and RegisteredKeybinds[mName] or nil
                if bs then SyncKeybindRow(bs, row) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_RefreshDisplayKey",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:RefreshDisplayKey",
        function(Context)
            local row = Context:get()
            ExecuteInGameThread(function()
                if not Core.IsValidObj(row) then return end
                local okN, mName = pcall(function() return row.MappingName:ToString() end)
                local bs = okN and RegisteredKeybinds[mName] or nil
                if bs then SyncKeybindRow(bs, row) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_OnKeySelected",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_InputKeySelector_K2Node_ComponentBoundEvent_0_OnKeySelected__DelegateSignature",
        function(Context, SelectedKeyParam)
            local row = Context:get()
            if not Core.IsValidObj(row) then return end
            local okN, mName = pcall(function() return row.MappingName:ToString() end)
            local bs = okN and RegisteredKeybinds[mName] or nil
            if not bs then return end

            local okKey, keyName = pcall(function()
                local chord = (type(SelectedKeyParam.get) == "function") and SelectedKeyParam:get() or SelectedKeyParam
                return chord.Key.KeyName:ToString()
            end)
            if okKey and keyName and keyName ~= "" and keyName ~= "None" then
                ApplyKeybindState(bs, keyName, true)
            end
            SyncKeybindRow(bs, row)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_Revert",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_RevertToDefaultButton_K2Node_ComponentBoundEvent_1_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not Core.IsValidObj(row) then return end
            local okN, mName = pcall(function() return row.MappingName:ToString() end)
            local bs = okN and RegisteredKeybinds[mName] or nil
            if not bs then return end
            ApplyKeybindState(bs, bs.DefaultKey, true)
            SyncKeybindRow(bs, row)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_Clear",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_ClearMappingButton_K2Node_ComponentBoundEvent_2_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not Core.IsValidObj(row) then return end
            local okN, mName = pcall(function() return row.MappingName:ToString() end)
            local bs = okN and RegisteredKeybinds[mName] or nil
            if not bs then return end
            ApplyKeybindState(bs, "None", true)
            SyncKeybindRow(bs, row)
        end
    )
    Core.TryRegisterHook(
        "Core_TextInput_OnCommitted",
        "/Game/Blueprints/Widgets/Basic/WBP_TextInput.WBP_TextInput_C:BndEvt__WBP_TextInput_EditableTextBox_80_K2Node_ComponentBoundEvent_1_OnEditableTextBoxCommittedEvent__DelegateSignature",
        function()
            ExecuteInGameThreadWithDelay(1, SyncCharacterInputSuppression)
        end
    )

    local okMenus, menus = pcall(FindAllOf, "WBP_SettingsMenu_C")
    if okMenus and menus then
        for _, m in ipairs(menus) do
            if Core.IsValidObj(m) then EnsureMenuKeybindRows(m) end
        end
    end
end

function Core.RegisterConfigurableKeybind(opts)
    local bs = {
        ConfigKey = opts.ConfigKey,
        DefaultKey = opts.DefaultKey,
        MappingName = opts.MappingName,
        Label = opts.Label,
        OnPress = opts.OnPress,
        OnChanged = opts.OnChanged,
        ActiveUe4ssKey = nil,
        FallbackPollActive = false,
        FallbackWasDown = false,
        MenuRows = {},
        TrackedRows = {},
    }
    RegisteredKeybinds[bs.MappingName] = bs
    Core.ReadConfig({ [bs.ConfigKey] = bs.DefaultKey })
    ApplyKeybindState(bs, Core.Config[bs.ConfigKey], false)
    Core.EnsureKeybindHooks()
    return bs
end

--------------------------------------------------------------------------------
-- Safe WBP_Button_C Click Registry (avoids UButton.OnPressed:Add crashes)
--------------------------------------------------------------------------------

local ButtonClickCallbacks = {}
local ButtonHookRegistered = false

function Core.RegisterWBPButtonClick(btn, fn)
    if not Core.IsValidObj(btn) or type(fn) ~= "function" then return end
    ButtonClickCallbacks[btn:GetAddress()] = fn

    if not ButtonHookRegistered then
        local ok = Core.TryRegisterHook(
            "Core_WBPButton_OnPressed",
            "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C:BndEvt__WBP_Button_Button_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature",
            function(Context)
                local w = Context:get()
                if Core.IsValidObj(w) then
                    local cb = ButtonClickCallbacks[w:GetAddress()]
                    if cb then
                        pcall(cb, w)
                    end
                end
            end
        )
        if ok then ButtonHookRegistered = true end
    end
end

return Core
