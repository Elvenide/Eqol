# AGENTS.md — Eqol (Elvenide's Quality of Life) for *Main Sequence*

## Project Overview

**Eqol** is a client-side UE4SS Lua quality-of-life mod for the Unreal Engine game *Main Sequence*.
It adds UI tools, overlays, hotkeys, and ergonomics (such as the Station Map, Power Overview, Logistics view, Elevator Labels/Hotkeys, Splitter/Balancer walk-through, HUD FPS/Version bar, and more) while keeping gameplay faithful to vanilla *Main Sequence*.

### Repository Structure
- `Scripts/main.lua` — Mod entrypoint; registers all feature modules and lifecycle hooks.
- `Scripts/core.lua` — Shared UE4SS utilities, config persistence, keybind registry, `Core.VERSION`, and safe reflection helpers.
- `Scripts/station_data.lua` — Shared station, floor, machine, wall collider, and port data extraction & caching layer.
- `Scripts/features/*.lua` — One self-contained Lua module per feature.
- `docs/*.md` — End-user feature documentation.
- `docs/devs/learning.md` — **Living developer knowledge base** for modding *Main Sequence* (UE4SS quirks, verified native RPCs, empty stubs, crash hazards, performance patterns).

---

## Mandatory Policies

1. **100% Save-Safe / Zero Save Dependency**:
   - Eqol MUST NEVER make a player's save file dependent on the mod.
   - Do **not** add custom blocks, custom items, custom recipes, custom serialized UObject classes, or persistent world/save-game mutations that cannot be cleanly undone simply by removing the Eqol mod folder.
   - Removing Eqol at any time must leave the save file 100% playable in vanilla *Main Sequence*.
2. **Never Modify or Commit `config.json`**:
   - `config.json` stores the user's local runtime settings and keybinds. It is gitignored and must never be modified or staged by agents.
3. **Check `docs/devs/learning.md` FIRST**:
   - Before implementing a new feature, calling a *Main Sequence* UFunction, reading simulation structs, or debugging a crash/no-op, **read `docs/devs/learning.md` first** to reuse verified solutions and avoid known dead ends or crash triggers.
4. **Update `docs/devs/learning.md` as a Living Document**:
   - Whenever you discover something significant about *Main Sequence* internals (e.g., a native RPC's exact parameter convention, an empty/stub UFunction, a UE4SS crash trigger, a struct memory layout, or a major UMG/Slate optimization), **update `docs/devs/learning.md`** and keep its Table of Contents accurate.

---

## Development & Verification Best Practices

- **Prefer Native Game Commands (`UInputCommand` / `DMSPlayerController`)**:
  - When mutating simulation state (building, disassembling, setting recipes, filters, priorities, port states), always prefer the game's native `DMSPlayerController:AddBuildCommand`, `AddDisassembleCommand`, and `AddInputCommand(InReceiverID, InCommand)` pathways so changes remain deterministic, refund/consume materials properly, and work in multiplayer.
- **Modular Features**:
  - Place each feature in `Scripts/features/<feature_name>.lua` implementing lifecycle hooks (`Init`, `RegisterHooks`, `OnMapLoad`, `OnClientRestart`, `OnWidgetConstructed`) and register it in `Scripts/main.lua`.
- **Keep UI & Rendering Incremental**:
  - Large stations can have 500+ machines and hundreds of wall colliders. Never synchronously construct hundreds of UMG widgets on a single frame; use cached UMG classes (`StaticConstructObject`), minimal widget counts, viewport-driven lazy loading, and time-budgeted frame streaming (`ExecuteInGameThreadAfterFrames(1, ...)`).
  - Never perform heavy work or call `ExecuteInGameThread` synchronously inside `WBP_Button_C` click hooks; defer with `ExecuteInGameThreadWithDelay(10, ...)`.
- **Defensive Lua & UE4SS Validation**:
  - Always guard UE4SS object/property accesses with `Core.IsValidObj(...)` and `pcall(...)`.
  - After every edit to any `.lua` file, run a Lua syntax and block-balance validator (`paren=0 brace=0 bracket=0 stackCount=0 errs=[]`) before committing.
- **Clean Commits**:
  - Stage only the files relevant to the task and verify `git status --short` before committing.
