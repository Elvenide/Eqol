# Hotbar Craftable Count Badges

Displays a compact numeric badge in the bottom-right corner of each bound hotbar slot showing how many of that machine you can currently build from your inventory.

## Features

- Automatically calculates the maximum buildable quantity for every bound slot on the bottom hotbar (`WBP_Hotbar_C`), checking both `ItemCost` and `ItemDetails.Recipe.Inputs`.
- **Color Coding**:
  - **White**: You have materials for at least 1 unit (large counts abbreviate cleanly, e.g., `1.2k`, `15k`).
  - **Red (`0`)**: You are missing one or more required materials.
  - **`∞`**: Shown automatically while in Creative Mode.
- Refreshes every `0.5s` and collapses cleanly on unbound/empty hotbar slots.
