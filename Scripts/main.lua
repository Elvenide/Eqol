-- Eqol (Elvenide's Quality of Life) mod for Main Sequence
-- Entrypoint: registers core utilities and individual feature modules.

do
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    local scriptDir = src:match("^(.*)[/\\][^/\\]+$")
    if scriptDir and scriptDir ~= "" then
        local luaPattern = scriptDir .. "/?.lua"
        if not package.path:find(luaPattern, 1, true) then
            package.path = luaPattern .. ";" .. package.path
        end
    end
end

local Core = require("core")

-- Feature modules (one script file per feature)
Core.RegisterFeature(require("features.power_overview"))
Core.RegisterFeature(require("features.station_map"))
Core.RegisterFeature(require("features.logistics"))
Core.RegisterFeature(require("features.designer_power_stats"))
Core.RegisterFeature(require("features.cinematic_freecam"))
Core.RegisterFeature(require("features.ship_camera"))
Core.RegisterFeature(require("features.conveyor_scroll_rotate"))
Core.RegisterFeature(require("features.ship_zero_throttle"))
Core.RegisterFeature(require("features.player_nametags"))
Core.RegisterFeature(require("features.player_map_markers"))
Core.RegisterFeature(require("features.player_alerts"))
Core.RegisterFeature(require("features.elevator_labels"))
Core.RegisterFeature(require("features.elevator_hotkeys"))

-- Startup
Core.InitAll()
Core.EnsureAllHooks()

pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart", function()
    Core.DispatchClientRestart()
end)

RegisterInitGameStatePostHook(function()
    Core.DispatchMapLoad()
end)

RegisterLoadMapPostHook(function()
    Core.DispatchMapLoad()
end)

NotifyOnNewObject("/Script/UMG.UserWidget", function(widget)
    if not Core.IsValidObj(widget) then return end

    local okCls, cls = pcall(function() return widget:GetClass() end)
    if not okCls or not Core.IsValidObj(cls) then return end

    local okName, clsName = pcall(function() return cls:GetFName():ToString() end)
    if not okName or not Core.IsWatchedWidgetClass(clsName) then return end

    if IsInGameThread() then
        Core.EnsureAllHooks()
        ExecuteInGameThreadAfterFrames(1, function()
            if Core.IsValidObj(widget) then
                Core.DispatchWidgetConstructed(widget, clsName)
            end
        end)
    else
        ExecuteInGameThread(function()
            Core.EnsureAllHooks()
            if Core.IsValidObj(widget) then
                Core.DispatchWidgetConstructed(widget, clsName)
            end
        end)
    end
end)

Core.Log(string.format("Initialized (Power Overview keybind: %s)", tostring(Core.Config.PowerOverviewKey)))
