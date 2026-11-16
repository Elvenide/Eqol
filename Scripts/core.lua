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
    local fpMath = Core.GetCDO(Core.PATHS.FPMathCDO)
    if Core.IsValidObj(fpMath) then
        local ok, val = pcall(function() return fpMath:GetFloat(fpNum) end)
        if ok and type(val) == "number" then
            return val
        end
    end
    return 0.0
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

function Core.GetLocalPlayerController()
    local ok, list = pcall(FindAllOf, "BP_PlayerController_C")
    if ok and list then
        for _, pc in ipairs(list) do
            if Core.IsValidObj(pc) then
                local okLocal, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
                if okLocal and isLocal then
                    return pc
                end
            end
        end
    end
    local fallback = UEHelpers.GetPlayerController()
    if Core.IsValidObj(fallback) then
        local okLocal, isLocal = pcall(function() return fallback:IsLocalPlayerController() end)
        if okLocal and isLocal then
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

function Core.EnsureAllHooks()
    for _, feature in ipairs(Features) do
        if type(feature.RegisterHooks) == "function" then
            feature.RegisterHooks(Core)
        end
    end
end

function Core.PruneAllCaches()
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

return Core
