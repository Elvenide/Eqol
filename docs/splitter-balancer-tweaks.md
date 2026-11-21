# Splitter, Balancer & Underground Belt Tweaks

Makes factory floors easier to navigate by letting you walk directly over Splitters and Belt Balancers, and compacts Splitters, Belt Balancers, and Underground Belts to 2/3 height.

## Features

- **Walk-Through Splitters & Belt Balancers**:
  - Disables player pawn collision (`ECC_Pawn`) on Splitters and Belt Balancers so you can walk across logistics lines smoothly—matching vanilla conveyor belts—while keeping building bounds and placement rules intact.
- **Compact 2/3 Height**:
  - Scales Splitter, Belt Balancer, and Underground Belt meshes vertically to **2/3 height** (`~0.67× Z`), anchored cleanly to the floor.
- **Instant & Automatic**:
  - Applies automatically to existing machines on map load and to newly built machines immediately upon construction.
