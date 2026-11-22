# HUD Version & FPS Bar

Enhances *Main Sequence*'s existing bottom-right version label in-place to show your live FPS alongside both the Eqol and *Main Sequence* version numbers.

![Bottom-right HUD version and FPS bar with menu keybind badges](images/hud-version-and-new-menus.png)
*Bottom-right HUD showing the live FPS, Eqol version, and Main Sequence version below the station menu keybind indicators.*

## Format

```text
FPS: <fps> | Eqol v<eqol version> | MS v<main sequence version>
```

## Details

- Edits the vanilla bottom-right version text in-place with frames per second and Eqol version information.
- Updates FPS twice per second (`0.5s` window) with minimal overhead.

## Notes

- If you have a question or find a bug in Eqol, it's helpful for me to know the Eqol and Main Sequence versions that are shown in this text label.
