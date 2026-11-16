# Logistics UI Screen

Inspect your station's total stored inventory and production/consumption throughput at a glance.

## Opening Logistics

- Press **`L`** (default) while on foot in a space station to toggle the **Logistics** window.
- A **Logistics** keybind indicator also appears in the bottom-right HUD while on foot in a station (automatically collapsing when piloting a ship or outside a station) and updates automatically if you rebind the key.

## Features

- **Station Container Storage Grid (Top-Left)**:
  - Aggregates all items currently stored across every container on your station into an inventory-style icon grid, sorted by quantity.
- **Total Production Rates (Bottom-Left)**:
  - 2-column summary showing the combined items/min production rate for every item produced on your station.
- **Production & Consumption Rate Monitor**:
  - Lists every production machine (assemblers, advanced assemblers, refineries, etc.) on the station in an icon-heavy layout.
  - Displays each ingredient's icon and consumption rate (**items/min**) alongside the output item's icon and production rate (**items/min**).
  - **Bottleneck Status Indicator** (hover over any machine row for a detailed status tooltip):
    - **Green**: All ingredients are being produced on the station at or above the total consumption rate.
    - **Red**: At least one ingredient is being consumed faster than the station is producing it (deficit/bottleneck).
    - **Amber**: No recipe is currently assigned.

## Configuration

- **In-Game**: Open **Settings → Controls** and look for **Logistics** to rebind the key, revert to default (`L`), or clear the binding.
- **Config File**: Stored in `Eqol/config.json` under `"LogisticsKey"`.
