-- Eqol Feature: Cinematic Freecam Toggle
-- Configurable keybind (default C) that toggles built-in Spectator Mode and Hide HUD simultaneously.

local Core = require("core")

local Feature = {
    Name = "CinematicFreecam",
}

local FreecamActive = false
local HookedSpecFn = false

local function EnsureSpecHook(pc)
    if HookedSpecFn or not Core.IsValidObj(pc) then return end
    local cls = pc:GetClass()
    if not Core.IsValidObj(cls) then return end
    local full = cls:GetFullName()
    local clsPath = full and full:match("^Class (.+)$") or nil
    if not clsPath then return end
    local fnPath = clsPath .. ":SetSpectatorMode"
    if Core.TryRegisterHook("Freecam_WatchSetSpectator", fnPath, function(Context, bNew)
        local ctrl = Context:get()
        local val = nil
        pcall(function() val = (type(bNew.get) == "function") and bNew:get() or bNew end)
        local pawnValid = Core.IsValidObj(ctrl) and Core.IsValidObj(ctrl.SpectatorModePawn)
        Core.Log(string.format("Freecam Hook [SetSpectatorMode] bNew=%s SpectatorModePawn=%s", tostring(val), tostring(pawnValid)))
    end) then
        HookedSpecFn = true
    end
end

local function ToggleCinematicFreecam()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    EnsureSpecHook(pc)
    FreecamActive = not FreecamActive

    pcall(function() pc:SetSpectatorMode(FreecamActive) end)
    pcall(function() pc:UpdateSpectatorTransform() end)
    pcall(function() pc:SetHUDHidden(FreecamActive) end)
    local pawnValid = Core.IsValidObj(pc.SpectatorModePawn)
    Core.Log("Cinematic Freecam: " .. (FreecamActive and "ON" or "OFF") .. " (SpectatorModePawn=" .. tostring(pawnValid) .. ")")
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
