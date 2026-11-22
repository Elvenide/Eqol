# Main Sequence Modding Knowledge Base (`learning.md`)

A living developer reference documenting verified *Main Sequence* internals, native RPCs, struct layouts, UE4SS quirks, crash triggers, and performance patterns discovered while building **Eqol**.

> **Maintainer Rule**: Check this document before implementing or debugging *Main Sequence* features, and update it (along with the Table of Contents) whenever you discover a new verified behavior, stub, or pitfall.

---

## Table of Contents

1. [Simulation Architecture & Coordinate Systems](#1-simulation-architecture--coordinate-systems)
2. [Building & Disassembling Machines](#2-building--disassembling-machines)
3. [Machine Configuration & `UInputCommand` System](#3-machine-configuration--uinputcommand-system)
4. [Underground Belts](#4-underground-belts)
5. [Station Geometry, Floors & Interior Walls](#5-station-geometry-floors--interior-walls)
6. [Known Crashes, Empty Stubs & UE4SS Pitfalls](#6-known-crashes-empty-stubs--ue4ss-pitfalls)
7. [UMG & Slate Performance Best Practices](#7-umg--slate-performance-best-practices)
8. [HUD, Cursor & Input Patterns](#8-hud-cursor--input-patterns)
9. [Binary Inspection Notes](#9-binary-inspection-notes)

---

## 1. Simulation Architecture & Coordinate Systems

- **Deterministic Simulation (`DMSWorld`)**:
  - *Main Sequence* runs a deterministic fixed-point simulation (`UDMSWorld` via `WorldSubsystem:GetDMSWorld()`) separate from Unreal Actors.
  - Simulation objects (`UStationObject`, `UMachineObject`, `USplitterObject`, `UAssemblerObject`, `UConveyorBeltObject`, `UUndergroundBeltObject`, etc.) own an integer `ID` and optionally spawn a visual `Actor` (`m.Actor`).
- **Fixed-Point Math (`PVector`, `PQuat`, `PFloat` / `PNum`)**:
  - Unreal strips the `F` prefix in reflected `UScriptStruct:GetFName()`, so `FPVector` reports as `"PVector"` and `FPQuat` reports as `"PQuat"`.
  - Each axis (`X`, `Y`, `Z`, `W`) is a nested struct with an `Int32` field `.Value` encoded in **Q16.16 fixed-point** (`real_value = Value / 65536.0`, `Value = math.floor(real_value * 65536.0 + 0.5)`).
  - `ChunkLocation` is `FIntVector` (reflected name `"IntVector"`): plain integers `{ X, Y, Z }`.
- **Units & Grid Scale**:
  - **1 Station Grid Cell** = `100 cm` (`1.0 m`) visually on the station floor.
  - **`Location` (`PVector`) on machines** is in **meters** (`stationLocalCm / 100.0`).
  - **`GridTransform`** (`{ GridLocation = FIntPoint{X, Y}, Height = Int32, GridRotation = Int32 }`) uses **`50 cm` half-cell units** (`gridDiv = 50.0`, `heightDiv = 50.0`), relative to the **Station origin** (`UStationObject`), NOT relative to individual station block modules.
    - Example: Floor 6 at `localZ = 4000 cm` has `Location.Z = 40.0` and `GridTransform.Height = 80` (`4000 / 50 = 80`).
    - `GridRotation` is `0..3` in `90°` steps (`((math.floor(yawDeg / 90 + 0.5) % 4) + 4) % 4`).

---

## 2. Building & Disassembling Machines

### Building: Use `AddBuildCommand` (NOT `AddBuildMachineCommand`!)
- **`DMSPlayerController:AddBuildMachineCommand` IS AN EMPTY NO-OP STUB**:
  - Disassembly of `execAddBuildMachineCommand` (`0x144286200`) proved it pops the `BuildMachineCommand` struct off the Blueprint stack and immediately returns without calling anything. Calling it returns `ok=true` from Lua while doing nothing.
- **`DMSPlayerController:AddBuildCommand(FBuildCommand)` IS THE REAL BUILD ENTRY POINT**:
  - Called by `UBuilder::ConfirmBuild` (`0x144319BF0`) at all 7 native build sites.
  - Exact `FBuildCommand` struct fields:
    - `Buildable` (`ObjectProperty`): `UBuildable*` (e.g. `DAT_Assembler`, `DAT_ConveyorBelt`).
    - `Location` (`StructProperty:PVector`): Q16.16 fixed-point meters `{ X={Value=...}, Y={Value=...}, Z={Value=...} }`.
    - `Quat` (`StructProperty:PQuat`): Q16.16 fixed-point quaternion `{ X={Value=...}, Y={Value=...}, Z={Value=...}, W={Value=...} }`.
    - `ChunkLocation` (`StructProperty:IntVector`): integer chunk coords from `station.ChunkLocation`.
    - `SolarSystemID` (`IntProperty`): from `station.SolarSystemID`.
    - `AttachTargetID` (`IntProperty`): **`station.ID`** (the `UStationObject.ID`, NOT the sub-module block ID).
    - `GridTransform` (`StructProperty:GridTransform`): `{ GridLocation = { X = gx, Y = gy }, Height = gz, GridRotation = rotSteps }`.
    - `Config` (`IntProperty`): `0` for normal machines; **`lengthInCells + 1`** for underground belts (see [Underground Belts](#4-underground-belts)).
    - `MachineConfigData` (`ArrayProperty`): omit to leave default-initialized empty `TArray`.
  - Material consumption and placement validation are handled natively by the simulation.

### Disassembling: `AddDisassembleCommand`
- **`DMSPlayerController:AddDisassembleCommand(DisassembleTarget: IntProperty, bMassDisassemble: BoolProperty)`**:
  - Pass `(machine.ID, false)` to disassemble a machine natively and automatically refund its build cost to the player's inventory.

---

## 3. Machine Configuration & `UInputCommand` System

All deterministic machine configuration changes are submitted via **`DMSPlayerController:AddInputCommand`**, which takes **TWO** arguments:
```lua
pc:AddInputCommand(receiverMachineId, inputCommandObj)
```
> **Pitfall**: Calling `pc:AddInputCommand(cmdObj)` with 1 argument silently fails inside `pcall` due to parameter mismatch!

### Verified `UInputCommand` Factories & Methods

| Purpose | Class & Method | Call Pattern | Notes |
| --- | --- | --- | --- |
| **Assembler / Refinery Recipe** | `SetRecipeInput:CreateInputSetRecipe(InRecipe)` | Static on CDO `Default__SetRecipeInput` | Returns `USetRecipeInput*`. |
| **Splitter / Balancer Filters** | `SetItemInput:CreateInputSetItem(InItemStack, InConfig)` | Static on CDO `Default__SetItemInput` | `InItemStack = { Item = itemObj, Count = 1 }`, `InConfig = 0-based port index`. Stored on machine in `m.Filters`. |
| **Splitter / Balancer Priorities** | `SetConfigInput:CreateInputSetConfig2(InConfig, InConfig2, InPlayerObjectID)` | Static on CDO `Default__SetConfigInput` | **Verified live**: `InConfig = 0` sets **`PriorityOutputIndex = InConfig2`**; `InConfig = 1` sets **`PriorityInputIndex = InConfig2`**. |
| **Disable / Enable Machine Ports** | `MachinePortInput:TogglePortEnabled(InPortIndex)` | **Void instance method!** | Construct fresh instance via `StaticConstructObject(MachinePortInputCls, pc)`, call `cmd:TogglePortEnabled(portIdx)` (sets `PortIndex` and `CommandType = 0x11`), then `pc:AddInputCommand(receiverId, cmd)`. **Do NOT call on CDO** (returns `nil`). |
| **Working / Paused State** | `SetWorkingInput:CreateInputSetWorking(bInWorking)` | Static on CDO `Default__SetWorkingInput` | Returns `USetWorkingInput*`. |
| **Logistic Filters** | `LogisticFilterInput:CreateInputLogisticFilter(InIndex, InItemStack, InAction, bInRemove)` | Static on CDO `Default__LogisticFilterInput` | Used for container/dock logistic filters. |

### Reading Disabled Ports (`m.PortStates`)
- `UMachineObject` stores port enabled states in **`m.PortStates`** (`TArray<bool>`), available on Splitters, Belt Balancers, Assemblers, Refineries, etc.
- `UAssemblerObject:IsPortEnabled(PortIndex)` (`execIsPortEnabled` at `0x144214470`) simply bounds-checks `PortIndex < PortStates.ArrayNum` and returns `PortStates[PortIndex]`.
- **Two Critical Pitfalls**:
  1. **Never pass `PortStates[i]` through `Core.UnwrapArrayElem`**: `Core.UnwrapArrayElem` returns `nil` when a boolean value is `false`! Read `local val = m.PortStates[i]` directly and test `if val == false then ... end`.
  2. **Never use the class CDO's `IsPortEnabled` as a default reference**: `PortStates` is empty on the CDO, so `cdo:IsPortEnabled(i)` always returns `false`.
  3. **Timing**: When applying both a recipe and disabled ports to a newly built machine, delay `TogglePortEnabled` by ~`200ms` after `SetRecipeInput` so the machine's ports are initialized first.

---

## 4. Underground Belts

- **Single Simulation Object**: An underground belt pair is **ONE single `BP_UndergroundBeltObject_C`** simulation object and actor!
  - Both visual endpoints (`S_Underground_Belt_01` at local `(0, 0)` and `S_Underground_Belt_02` at local `(0, -dist)`) are mesh components on the same actor.
- **Building with Exact Distance**:
  - Submit **ONE** `AddBuildCommand` at the entrance position with `Config = math.floor(centerToCenterDistCm / 100.0 + 0.5) + 1`.
  - Example: A gap of `2` empty cells between entrance and exit has a center-to-center distance of `3` cells (`300 cm`), so `Config = 3 + 1 = 4`. Sending `Config = 3` builds a gap of only `1` cell.
  - Submitting two `AddBuildCommand`s (one per end) will spawn two separate underground belt pairs.

---

## 5. Station Geometry, Floors & Interior Walls

- **Interior Walls & Doorways**:
  - Read directly from `station:GetCollisionEnv().Colliders` via UE4SS `RegisterCustomProperty`.
  - Each entry is a **28-byte `FCharacterCollider`**:
    - `+0x00`: `FPVector Min` (3× Q16.16 int32 = 12 bytes)
    - `+0x0C`: `FPVector Max` (3× Q16.16 int32 = 12 bytes)
    - `+0x18`: `ColliderID` (int32 = 4 bytes)
  - Scale factor to cm: `100.0 / 65536.0`.
  - Merge collinear wall segments before rendering, and draw as a 2-pass continuous shape (expanded border pass at `Z=5`, opaque fill pass at `Z=6`) so adjacent wall segments merge seamlessly without internal seams.
- **Walk-Through Collision Patching** (used by `splitter_balancer_tweaks.lua`):
  - Setting `bColliderEnabled = false` on splitter/balancer simulation objects disables character collision while keeping `MachineBounds` / building placement intact.
  - **Multiplayer Rule**: Because walk-through mutates local simulation collision envelopes and CDO `bColliderEnabled`, it MUST be automatically disabled in multiplayer sessions (detect via `UKismetSystemLibrary:IsStandalone(pc) == false`, `World:GetNetMode() ~= 0`, or `GameState.PlayerArray > 1`) to avoid client/server movement desync. Visual-only mesh scaling (2/3 height) remains safe in multiplayer.
  - **Underground Belt Mesh Scaling (`BP_UndergroundBeltActor_C`)**: `S_Underground_Belt_02` has a live world-dependent `RelativeLocation.X/Y` representing the underground belt span. When scaling Z or restoring original height, always read live `RelativeLocation.X/Y` and only update `Z`—never overwrite `X/Y` with CDO/archetype `(0, 0)`.

---

## 6. Known Crashes, Empty Stubs & UE4SS Pitfalls

### Guaranteed Crash Triggers (NEVER CALL THESE!)
- **UE4SS `0x18` Access Violation Crashes**:
  - `actor:GetActorRightVector()`
  - `comp:IsVisible()`
  - `comp.StaticMesh:GetFName()`
  - `comp:K2_GetComponentLocation()` inside `GetPlatformWorldBounds`
  - Reading `machine.InputMachines` or `machine.OutputMachines` directly in hot loops
- **Other Fatal / Freeze Pitfalls**:
  - **Calling `UMachineObject:GetDisplayMaxPower()` or `GetDisplayPower()` on CDOs**: Ship machine CDOs lack a runtime `BuildingFrame` and crash reading `[Frame + 0x48]`. Always read safe reflected numeric properties on CDOs instead.
  - **Calling `UBuildingBlockObject:GetDefaultMachine()` outside its expected frame type**: Dereferences a null `Cast<Frame>` pointer at `+0x188` and crashes. Read reflected properties (`DefaultMachine`, `DefaultMachines`, `AttachedMachines`) instead.
  - **Reading `.Z` on `FIntPoint`**: Throws in UE4SS (`FIntPoint` only has `X` and `Y`).
  - **Calling `ExecuteInGameThread` / `ExecuteInGameThreadAfterFrames` synchronously inside a `WBP_Button_C` click hook**: Causes hangs/freezes. Always defer heavy button actions with `ExecuteInGameThreadWithDelay(10, fn)`.
  - **Setting `CurrentFloors[idx].machines = nil`**: Previously triggered a legacy world-coordinate fallback that generated 100k grid lines and froze the game.
  - **Wiping `CachedFloorMap = nil` inside `InvalidateMachineCache()`**: Forces a ~470ms full platform + 853-wall-collider rebuild on the next map open. Only clear `CachedMachinesByFrame = {}` when refreshing machines.
  - **Calling `DestroyStationMap()` from `WBP_WindowBase_C`'s `CloseWindow` delegate**: Destroys the cached window when clicking the `X` button; call `CloseStationMap()` instead and re-add `ActiveMapWin:AddToViewport(50)` on reopen if needed.
  - **`NotifyOnNewObject("/Script/MainSequence.DMSObject", ...)` does NOT catch newly built machines**: Station machines (`BP_ConveyorBeltObject_C`, `BP_SplitterObject_C`, `BPO_BeltBalancer_*_C`, `BP_UndergroundBeltObject_C`, etc.) inherit from `/Script/MainSequence.MachineObject` (and specific subclasses like `/Script/MainSequence.ConveyorBeltObject`), not `DMSObject`. Always hook `"/Script/MainSequence.MachineObject"` (or the specific machine subclass) when watching for newly constructed machines.

### Empty / Dead Stubs
- `DMSPlayerController:AddBuildMachineCommand` — Completely empty no-op stub (use `AddBuildCommand`).

---

## 7. UMG & Slate Performance Best Practices

- **Cache UMG Classes (`StaticConstructObject`)**:
  - Calling `Core.CreateRawWidget` (which calls `StaticFindObject` on every call) thousands of times is very slow. Cache `UClass*` pointers (`CachedBorderCls`, `CachedWidgetClasses[path]`) and construct directly via `StaticConstructObject(cls, outer)`.
- **Minimize Widget Count Per Entity**:
  - Slate's per-frame layout/paint cost scales directly with total UMG widget count.
  - Example: Reducing item port badges from `13` `UBorder` widgets (12 dashes + fill) to `2` `UBorder` widgets cut Floor 1 port widgets from `4,654` to `716` (6.5× fewer!).
  - Example: Drawing conveyors directly onto `MachineCanvas` with `4` `UBorder`s instead of a `CanvasPanel` + `6` borders cut conveyor widget count nearly in half.
- **Separate Static vs. Dynamic Canvas Layers**:
  - Keep static geometry (`MapCanvas` at `Z=0`: grid lines, module fills/outlines, walls) separate from dynamic geometry (`MachineCanvas` at `Z=1`: machines, conveyors, ports, player markers) and selection/ghosts (`SelectionCanvas` at `Z=2`, `GhostPreviewCanvas` at `Z=3`).
  - Track widgets per machine (`RenderedMachineWidgets[mAddr]`) and per underground pair (`undergroundPairWidgets[pKey]`) so deletions and `Apply Changes` only touch changed machines without clearing or redrawing the whole floor.
- **O(1) Ghost Group Dragging**:
  - Place `GhostPreviewCanvas` inside `bgPanZoom` (base-canvas space). Build the ghost widgets **once** per clipboard/rotation signature, and on mouse move update only `GhostPreviewSlot:SetPosition({ X = bx, Y = by })` — 0 widget allocations per frame even for 200+ ghosts.
- **Viewport-Driven Lazy Streaming (Never Unload)**:
  - Start zoomed in around the player's position and only construct widgets for walls/machines that intersect the padded visible viewport (`~35%` / 6-cell margin), streaming within an `8–10ms/frame` budget. Once created, keep them permanently on the canvas so panning has zero pop-out or visual flicker.
- **Never Call `GetFrameMachines()` in a Loop Over `GetStationPlatforms()`**:
  - `StationData.GetStationPlatforms(station)` includes non-machine hull/room/module subobjects. Calling `GetFrameMachines(plat)` on each one triggers `FindAllOf("MachineObject")` for every subobject with 0 machines, causing a permanent freeze on large stations. Use `StationData.GetStationMachines(station, walkFrame)` instead (runs at most one `FindAllOf("MachineObject")` pass and matches each machine's `ParentFrame` against the station's frame set).
- **Avoid Frequent Background `FindAllOf` Polls**:
  - Running `FindAllOf` across many classes every `0.85s–1.5s` causes visible periodic frame drops. Prefer `NotifyOnNewObject` + O(1) property reads (`pc.Builder`, cached widget refs) and keep safety-net scans infrequent (`>= 8.0s`).

---

## 8. HUD, Cursor & Input Patterns

- **Custom Cursor Hotspot**:
  - Inside `WBP_WindowBase_C` framed windows, *Main Sequence*'s custom white arrow cursor had its Slate coordinate aligned ~`15px` below the tip (`ly = ly - 15.0`); inside a plain fullscreen `/Script/UMG.UserWidget` root (`SetAnchorsInViewport({0,0},{1,1})`), `AbsoluteToLocal` aligns directly with the cursor tip without a Y-offset.
- **Ship Piloting, Camera & Telemetry Internals (`ship_camera.lua`, `ship_zero_throttle.lua`)**:
  - Active piloted ship is at `pc.PlayerObject.PilotedShip` (always guard `pc.PlayerObject` and `po.PilotedShip` in `pcall`).
  - `shipObj:SetViewedExternally(bool)` toggles external ship rendering for 3rd-person camera; throttle can be stepped natively via `pc:SetThrottleInput(axis)`.
  - Verified live telemetry properties/methods on `shipObj`: `bBoosting` (`bool`), `BoostCharge` / `MaxBoostCharge`, `GetVelocity()` / `Velocity`, `GetTotalFuel()` (reserve cells) + `GetRemainingFuel()` (active burning cell buffer) where **1 raw fuel unit = `0.01 MJ` (`10 kJ`)**, `FuelConsumptionRate`, `GetCurrentHull()` / `GetTotalHull()`, `GetShields()` / `GetMaxShields()`.
- **Single-Frame Mouse Scroll Polling**:
  - `pc:WasInputKeyJustPressed({ KeyName = FName("MouseScrollUp") })` is only true for a **single game frame**. Polling it with `ExecuteInGameThreadWithDelay(16, ...)` skips frames and feels insensitive. Always poll scroll input with `ExecuteInGameThreadAfterFrames(1, ...)` and also check `pc:GetInputAnalogKeyState({ KeyName = FName("MouseWheelAxis") })`.
  - Any active builder on `pc.Builder` (`ConveyorBuilder`, `MachineBuilder`, `UndergroundBeltBuilder`, etc.) exposing `:AddRotation(delta)` can be rotated in O(1) without `FindAllOf`.
- **HUD Top-Right Input Icons (`WBP_CharacterHUD_C.HUDInputContainer`)**:
  - Row 0 (`Tab`, `B`, `X`) is shifted ~`22px` right relative to Row 1 (`Y`, `M`, `T`, `G`, `K`). Hosting custom station indicators (`Power`, `Station Map`, `Logistics`) inside an unclipped `1×1` `SizeBox` wrapping a `CanvasPanel` in `(Row=0, Col=1)` with a right-anchored `HorizontalBox` (`Alignment = {1.0, 0.5}`, `AutoSize = true`, `Position.X = nudgeX`) aligns them evenly to the left of `Tab` without stretching Column 1 (`M`) or shifting Row 1.
- **Bottom Hotbar (`WBP_Hotbar_C` / `WBP_HotbarSlot_C`) & `UBuildable` Costs**:
  - `WBP_Hotbar_C.WidgetTree` is not exposed in shipping builds; discover its 10 `WBP_HotbarSlot_C` children via `ForEachProperty` on `WBP_Hotbar_C` (and attach overlays by wrapping `slot.Image_60` inside its parent `Border` with a new `UOverlay`).
  - `HotbarBuildables` is indexed by key digit `0..9` in C++ (`1..10` in Lua): `ability0`/`ability10` maps to Lua index `1`, and `ability1..ability9` map to Lua indices `2..10` (`luaIdx = (num % 10) + 1`).
  - `UBuildable` stores costs in `ItemCost` (`bUseItemCost`) and `ItemDetails.Recipe.Inputs` (`bItemCostAsBuildingCost`).
- **Conveyor Belt Pulling & `AddRotation`**:
  - `UBuilderBase::AddRotation` always steps `+1` regardless of sign. Normal 4-way placement wraps mod 4 (`1×` = `+90°`, `3×` = `-90°`); while pulling out a conveyor belt, routing wraps mod 3 (`1×` forward, `2×` backward).
  - `ConfirmBuild` invokes `AddBuildCommand` directly in C++ (bypassing UE4SS UFunction hooks on `AddBuildCommand`); detect when pulled conveyor segments commit by hooking `NotifyOnNewObject("/Script/MainSequence.ConveyorBeltObject", ...)`.
- **In-Place HUD Version Text**:
  - The bottom-right version string (e.g. `0.1.0.109s`) is a standard `UTextBlock` discoverable via `FindAllOf("TextBlock")` matching `^[vV]?%d+%.%d+%.%d+`.
  - Editing it in-place with `tb:SetText(...)` and `tb.Slot:SetAutoSize(true)` preserves the exact vanilla font, size, color, and styling.
- **Modifier Keybinds**:
  - Use `RegisterKeyBind(Key.C, { ModifierKey.CONTROL }, ...)` for `Ctrl+C` (with `IsInputKeyDown("LeftControl"/"RightControl")` fallback).
- **Widget Caching**:
  - Hide reusable `WBP_WindowBase_C` windows with `SetVisibility(1)` (`Collapsed`) instead of destroying them for ~3ms reopens.
- **Settings Menu Tab Injection (`WBP_SettingsMenu_C` / `WBP_CleanTab_C`)**:
  - `WBP_SettingsMenu_C` hosts its top tab bar in a `UGridPanel` (`GridPanel_207`) paired with a `UWidgetSwitcher`.
  - Instantiating the same native `WBP_CleanTab_C` class as sibling tabs matches vanilla styling, but do **not** wire `nativeTab.WidgetSwitcher` / `nativeTab.Index` when using lazy page population—let the `WBP_Button` click handler populate the page first and then call `switcher:SetActiveWidget(pageScroll)` to avoid a 1-frame empty flash and double-trigger.
- **Main Menu Cursor Preservation**:
  - Never clear `pc.bShowMouseCursor` or set `GameOnly` input mode when `WBP_MainMenu_C` is visible (e.g., when closing a Settings or text-input focus state on the title screen).
- **Research Tree Search (`WBP_ResearchTree_2_C`)**:
  - Track only rows hidden by Eqol (`HiddenByEqol[addr] = origVis`) rather than snapshotting all rows, and clear `HiddenByEqol` whenever native `SetupWidget` / `SetFilter` / `RefreshList` runs so clearing search never un-hides techs hidden by a native filter tab.
- **Multiplayer Hook & RPC Discipline**:
  - Always guard `PlayerController` hooks (`ClientRestart`, `EnterBuildingMode`, `ConfirmBuild`, `Client_AddRemotePlayer`, `Client_RemovePlayer`, Designer hooks) with `pc:IsLocalPlayerController()` so remote clients on a listen-server host never trigger host-side UI/state resets.
  - Never mutate simulation properties directly (e.g. `stopObj.DoorOpenProgress`); always use native `AddInputCommand` / `AddBuildCommand` / `AddDisassembleCommand` / `AddQueueResearchCommand` RPCs, and poll replicated state with timeouts rather than assuming fixed local-RTT delays.

---

## 9. Binary Inspection Notes

When reflection alone is ambiguous, `MainSequence-Win64-Shipping.exe` (PE64, `ImageBase = 0x140000000`) can be inspected directly:
- **UE Reflection Table (`.rdata` around `0x7300000..0x73E0000`)**: Contains ASCII and UTF-16 `UClass` / `UScriptStruct` / `UFunction` / `FProperty` names and `FNativeFunctionLookup` tables pairing function name pointers with `exec*` native thunk VAs.
- **Verified Native Addresses (v0.1.0.109s)**:
  - `execAddBuildMachineCommand`: `0x144286200` (empty no-op stub)
  - `execAddBuildCommand`: `0x144286080` -> `ADMSPlayerController::AddBuildCommand`: `0x1442A31B0`
  - `UBuilder::ConfirmBuild`: `0x144319BF0` (calls `0x1442A31B0` at 7 sites)
  - `execTogglePortEnabled`: `0x144255D20` (void instance method setting `+0x40 = InPortIndex`, `+0x28 = 0x11`)
  - `execCreateInputSetConfig2`: `0x1442549C0` (`CommandType = 0x15`, `+0x40 = InConfig`, `+0x44 = InConfig2`, `+0x48 = InPlayerObjectID`)
  - `execIsPortEnabled`: `0x144214470` (reads `PortStates` `TArray<bool>` at `+0x250`, `ArrayNum` at `+0x258`)
