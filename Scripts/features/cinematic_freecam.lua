-- Eqol Feature: Cinematic Freecam Toggle
-- Configurable keybind (default C) that toggles built-in Spectator Mode and Hide HUD simultaneously.

local Core = require("core")

local Feature = {
    Name = "CinematicFreecam",
}

local FreecamActive = false
local HookedSpecFn = false
local MoveTickRunning = false

local function IsDown(pc, keyName)
    local ok, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(keyName) }) end)
    return ok and down == true
end

local function StartSpectatorMoveTick()
    if MoveTickRunning then return end
    MoveTickRunning = true

    local function Tick()
        if not FreecamActive then
            MoveTickRunning = false
            return
        end

        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and Core.IsValidObj(pc.Pawn) then
            local moveF = (IsDown(pc, "W") and 1 or 0) - (IsDown(pc, "S") and 1 or 0)
            local moveR = (IsDown(pc, "D") and 1 or 0) - (IsDown(pc, "A") and 1 or 0)
            local moveU = ((IsDown(pc, "SpaceBar") or IsDown(pc, "E")) and 1 or 0)
                        - ((IsDown(pc, "LeftControl") or IsDown(pc, "Q")) and 1 or 0)

            if moveF ~= 0 or moveR ~= 0 or moveU ~= 0 then
                pcall(function()
                    local speed = 12.0
                    if IsDown(pc, "LeftShift") then speed = 36.0 end
                    if IsDown(pc, "LeftAlt") then speed = 3.0 end
                    local vec = {
                        X = moveF * speed,
                        Y = moveR * speed,
                        Z = moveU * speed,
                    }
                    if pc.Pawn.AddSpectatorInput then
                        pc.Pawn:AddSpectatorInput(vec)
                    end
                end)
            end
        end

        ExecuteInGameThreadWithDelay(16, Tick)
    end

    ExecuteInGameThreadWithDelay(16, Tick)
end

local function EnsureSpecHook(pc)
    if HookedSpecFn or not Core.IsValidObj(pc) then return end
    local cls = pc:GetClass()
    if not Core.IsValidObj(cls) then return end
    local full = cls:GetFullName()
    local clsPath = full and full:match("^%S+ (.+)$") or nil
    if not clsPath then return end
    local fnPath = clsPath .. ":SetSpectatorMode"
    if Core.TryRegisterHook("Freecam_WatchSetSpectator", fnPath, function(Context, bNew)
        local ctrl = Context:get()
        local val = bNew
        pcall(function()
            if type(bNew.get) == "function" then val = bNew:get() end
        end)
        ExecuteInGameThreadWithDelay(100, function()
            if Core.IsValidObj(ctrl) then
                local sp = Core.IsValidObj(ctrl.SpectatorModePawn)
                local pName = Core.IsValidObj(ctrl.Pawn) and ctrl.Pawn:GetClass():GetFName():ToString() or "nil"
                Core.Log(string.format("Freecam Post [SetSpectatorMode(%s)] SpectatorModePawn=%s Pawn=%s", tostring(val), tostring(sp), pName))
            end
        end)
    end) then
        HookedSpecFn = true
        Core.Log("Freecam: hooked " .. fnPath)
    end

    pcall(function()
        if Core.IsValidObj(pc.Pawn) then
            local pCls = pc.Pawn:GetClass()
            if Core.IsValidObj(pCls) and pCls.ForEachFunction then
                pCls:ForEachFunction(function(fn)
                    local n = fn:GetFName():ToString()
                    if n == "AddSpectatorInput" or n == "UpdateSpectatorCamera" then
                        local params = {}
                        if fn.ForEachProperty then
                            fn:ForEachProperty(function(prop)
                                params[#params + 1] = prop:GetFName():ToString() .. ":" .. prop:GetClass():GetFName():ToString()
                            end)
                        end
                        Core.Log("Freecam Pawn Sig [" .. n .. "]: " .. table.concat(params, ", "))
                    end
                end)
            end
        end
    end)

    pcall(function()
        local gStatics = Core.GetCDO("/Script/Engine.Default__GameplayStatics")
        local gi = Core.IsValidObj(gStatics) and gStatics:GetGameInstance(pc) or nil
        if Core.IsValidObj(gi) then
            local giCls = gi:GetClass()
            if Core.IsValidObj(giCls) and giCls.ForEachFunction then
                giCls:ForEachFunction(function(fn)
                    local n = fn:GetFName():ToString()
                    if string.find(n, "Spectat", 1, true) then
                        Core.Log("Freecam Reflection [GameInstance fn]: " .. n)
                    end
                end)
            end
        end
    end)
end

local function ToggleCinematicFreecam()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    EnsureSpecHook(pc)
    FreecamActive = not FreecamActive
    local targetState = FreecamActive

    pcall(function() pc:SetSpectatorMode(targetState) end)
    if Core.IsValidObj(pc.Pawn) then
        pcall(function()
            if pc.Pawn.SetSpectatorMode then
                pc.Pawn:SetSpectatorMode(targetState)
            end
        end)
    end
    ExecuteInGameThreadWithDelay(50, function()
        if Core.IsValidObj(pc) then
            pcall(function() pc:SetHUDHidden(targetState) end)
        end
    end)
    if targetState then
        StartSpectatorMoveTick()
    end
    Core.Log("Cinematic Freecam: " .. (targetState and "ON" or "OFF"))
end

function Feature.RegisterHooks()
    local pc = Core.GetLocalPlayerController()
    if Core.IsValidObj(pc) then EnsureSpecHook(pc) end
end

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "CinematicFreecamKey",
        DefaultKey  = "C",
        MappingName = "Eqol_CinematicFreecam",
        Label       = "Cinematic Freecam",
        OnPress     = ToggleCinematicFreecam,
    })
end

function Feature.OnClientRestart()
    if FreecamActive then
        FreecamActive = false
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) then
            pcall(function() pc:SetSpectatorMode(false) end)
            pcall(function() pc:SetHUDHidden(false) end)
        end
    end
end

return Feature
