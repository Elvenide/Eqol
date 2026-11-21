# Full Station Map UI

View your entire space station floor-by-floor in 2D, inspect machines/ports/walls/players, delete machines, and copy-paste full machine layouts with staged ghost previews.

## Opening the Station Map

- Press **`N`** (default) while on foot in a space station to toggle the **Station Map** window (or press **`Escape`** while open to close it).
- A **Station Map** keybind indicator also appears in the top-right HUD alongside **Power (`P`)** and **Logistics (`L`)** while on foot in a station, updating automatically if you rebind the key.
- You can rebind this key in **Settings → Controls** under **Station Map** (stored in `Eqol/config.json` as `"StationMapKey"`).

## Features

- **Floor-by-Floor 2D Top-Down View**:
  - Displays station modules, interior walls and doorways, built machines, directional conveyors, underground belt pairs, item/power ports, and player markers on the active floor.
  - **Pan & Zoom**: Drag with the mouse to pan and scroll the mouse wheel to zoom smoothly around the cursor.
  - **Floor Navigation**: Use the vertical numbered floor buttons on the right side (`1`, `2`, `3`, …) with `↑` / `↓` pagination buttons to switch between floors.
- **Machine Icons & Hover Tooltips**:
  - Assemblers, refineries, containers, and conveyor belts display icons for the item they are producing, storing, or moving.
  - Hover over any machine or port to view a detailed tooltip (machine type, recipe/item, port direction/filter/enabled state, and priority).
- **Selection, Box-Select & Deletion (`X`)**:
  - Click a machine to select it, **`Shift` + Click** to toggle multiple machines in the selection, or **click and drag** to box-select a group of machines.
  - Press **`X`** (or click **Delete**) to stage selected machines for disassembly—normal material refunds apply when changes are applied.
- **Copy-Paste, Rotate (`R`), Smart Replace (`⇄`) & Ghost Staging**:
  - Click **Copy** (or press **`Ctrl+C`**) to copy the selected machine(s) and their relative layout—including **recipes, splitter/balancer filters, input/output priorities, disabled ports, and underground belt distances**.
  - Press **`R`** (or click **Rotate**) to rotate the ghost preview by 90° clockwise before placing.
  - Click on any floor to stage ghost placements. Pasting over an existing machine of a different type or orientation stages a **Smart Replace (`⇄`)** that disassembles the old machine and builds the new one cleanly, crediting the refunded materials toward the build check.
  - Click **Apply** to commit all staged builds/deletes/replacements natively via the game's build and disassemble commands (consuming/refunding normal inventory materials), or **Discard** to cancel all pending changes.
