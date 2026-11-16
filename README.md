# Eqol — Elvenide's Quality of Life Mod for Main Sequence

Client-side [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod implementing non-invasive, **100% save-safe and cleanly removable** quality-of-life improvements for **Main Sequence**.

---

## Features

1. **Power Overview Keybind (`P` by default)**
   - Press `P` anywhere inside a **space station** or **spaceship** (walking inside or piloting) to open the **Power Overview** window directly without walking up to a machine.
   - Press `P` again while **Power Overview** is open to close it.
   - Fully customizable in the game's **Settings -> Controls** menu via a native `"Power Overview"` keybind row (supports selecting a new key, **Revert to Default (`P`)**, and **Clear Mapping**).
   - Persisted separately in [config.json](config.json) so your save files and engine keybind configs remain untouched.

2. **Power Overview Header Progress Bars**
   - **Production (`Current / Max`)**: Static green progress bar right beneath the top Production totals.
   - **Consumption (`Current / Max`)**: Static green progress bar right beneath the top Consumption totals.
   - **Power Satisfaction (`Production / Consumption`)**: Progress bar in the top summary area across from Solar Panel Efficiency showing percentage and dynamic status colors:
     - **Green** when `Production >= Consumption`
     - **Amber** when `50% <= Production / Consumption < 100%`
     - **Red** when `Production / Consumption < 50%`

---

## Installation & Removal

- UE4SS (`v4.0.0`) is installed in `Main Sequence\Windows\MainSequence\Binaries\Win64\` (`dwmapi.dll` + `ue4ss/`).
- The mod is linked at `ue4ss\Mods\Eqol` via a directory junction pointing to this folder and enabled in `ue4ss\Mods\mods.txt` (`Eqol : 1`).
- **To disable or remove cleanly**: set `Eqol : 0` in `mods.txt` (or delete `enabled.txt` / the `Eqol` junction). Existing save files load identically with or without the mod.
