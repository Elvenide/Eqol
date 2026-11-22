# Getting Started with Eqol

> [!NOTE]
> **Main Sequence vs. Demo**: Eqol is tested and working in the full version of **Main Sequence**. While some features also work in the **Main Sequence Demo**, not all of them do. Eqol is developed exclusively for the full game, so using it in the full game is recommended and using it in the demo is not recommended.

**Eqol** (*Elvenide's Quality of Life*) is a client-side UE4SS Lua mod for **Main Sequence**. It is designed to be 100% save-safe and cleanly removable at any time without affecting your save files.

## Prerequisites

- **Main Sequence** installed via Steam (default: `C:\Program Files (x86)\Steam\steamapps\common\Main Sequence`)
- **UE4SS v4.0.0+** (Unreal Engine 5.7 compatible)

## Installation

Choose either **MSCoreManager** (recommended) or **Manual UE4SS Installation** below.

### Option 1: Install with MSCoreManager (Recommended)

1. **Install MSCoreManager & UE4SS** (if you haven't already):
   - Download the latest **MSCoreManager** executable by **xxalex3xx97** from [github.com/xxalex3xx97/MSCore/releases/latest](https://github.com/xxalex3xx97/MSCore/releases/latest).
   - Run `MSCoreManager` and follow its prompts to automatically install and configure UE4SS for *Main Sequence*.
2. **Install Eqol**:
   - Open **MSCoreManager** and click **Add mod...**.
   - Paste in `https://github.com/Elvenide/Eqol` to install automatically from GitHub Releases (MSCoreManager uses `manifest.txt` and **`Eqol-v<version>.zip`**).
   - *(Alternatively, if installing from a local archive in MSCoreManager, download **`Eqol-v<version>.zip`** from [github.com/Elvenide/Eqol/releases](https://github.com/Elvenide/Eqol/releases).)*
3. **Launch Main Sequence**:
   - Eqol will automatically create/update `Eqol\config.json` with default settings on first launch.
   - Open **Settings → Eqol** at any time to toggle individual features on or off, or **Settings → Controls** to rebind Eqol hotkeys.

### Option 2: Manual UE4SS Installation

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
   - Download **`Eqol-v<version>.zip`** from [github.com/Elvenide/Eqol/releases](https://github.com/Elvenide/Eqol/releases).
   - Open the zip, navigate into its `Mods\` folder, and copy the `Eqol` folder into:
     ```
     Main Sequence\Windows\MainSequence\Binaries\Win64\ue4ss\Mods\Eqol\
     ```
     *(You can safely leave `mscore.mod` inside `Eqol\`—UE4SS ignores it.)*
   - Ensure `Eqol\enabled.txt` exists (an empty file is fine).
   - Open `ue4ss\Mods\mods.txt` and add `Eqol : 1` **above** `Keybinds : 1`:
     ```ini
     Eqol : 1

     ; Built-in keybinds, do not move up!
     Keybinds : 1
     ```
3. **Launch Main Sequence**:
   - Eqol will automatically create/update `Eqol\config.json` with default settings on first launch.
   - Open **Settings → Eqol** at any time to toggle individual features on or off, or **Settings → Controls** to rebind Eqol hotkeys.

## Uninstalling

- Remove or rename `Eqol\enabled.txt` (or delete the `Eqol` folder and remove `Eqol : 1` from `mods.txt`).
- Your saves remain completely intact with no missing-mod dependencies.
