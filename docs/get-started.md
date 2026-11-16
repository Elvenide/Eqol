# Getting Started with Eqol

**Eqol** (*Elvenide's Quality of Life*) is a client-side UE4SS Lua mod for **Main Sequence**. It is designed to be 100% save-safe and cleanly removable at any time without affecting your save files.

## Prerequisites

- **Main Sequence** installed via Steam (default: `C:\Program Files (x86)\Steam\steamapps\common\Main Sequence`)
- **UE4SS v4.0.0+** (Unreal Engine 5.7 compatible)

## Installation

1. **Install UE4SS** (if you haven't already):
   - Download the latest UE4SS release (`UE4SS_v4.0.0.zip` or newer) from the [RE-UE4SS Releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases).
   - Extract the contents into your game's `Win64` folder:
     ```
     Main Sequence\Windows\MainSequence\Binaries\Win64\
     ```
     (You should see `dwmapi.dll` and the `ue4ss\` folder inside `Binaries\Win64\`.)
   - Open `ue4ss\UE4SS-settings.ini` and set the engine version override for Main Sequence:
     ```ini
     [EngineVersionOverride]
     MajorVersion = 5
     MinorVersion = 7
     ```

2. **Install Eqol**:
   - Download the latest release zip from [github.com/Elvenide/Eqol/releases](https://github.com/Elvenide/Eqol/releases).
   - Extract the `Eqol` folder into:
     ```
     Main Sequence\Windows\MainSequence\Binaries\Win64\ue4ss\Mods\Eqol\
     ```
   - Ensure `Eqol\enabled.txt` exists (an empty file is fine).
   - Open `ue4ss\Mods\mods.txt` and add `Eqol : 1` **above** `Keybinds : 1`:
     ```ini
     Eqol : 1

     ; Built-in keybinds, do not move up!
     Keybinds : 1
     ```

3. **Launch Main Sequence**:
   - Eqol will automatically create/update `Eqol\config.json` with default settings on first launch.

## Uninstalling

- Remove or rename `Eqol\enabled.txt` (or delete the `Eqol` folder and remove `Eqol : 1` from `mods.txt`).
- Your saves remain completely intact with no missing-mod dependencies.
