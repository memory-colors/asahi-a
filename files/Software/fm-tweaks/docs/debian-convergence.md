# Debian <-> Asahi: how the look is achieved, and what to align

Both machines should look essentially identical (differences only in subtle colors and scaling). This is the list of *mechanism* differences found on 2026-10-14
(architecture aside) and the state after the Asahi-side streamlining. Debian items are for the Debian session; nothing here was run on Debian.

| # | Difference | Asahi now | Do on Debian |
|---|---|---|---|
| 1 | QSS delivery | per-app `-stylesheet` of `dolphin-theme.qss`; qt6ct has no `stylesheets=` | qt6ct *replaces* the application stylesheet, so with a global qt6ct QSS the per-app flag is dead. **Interim:** set qt6ct `stylesheets=` to the generated `<out>/dolphin-theme.qss` (shared + Dolphin rules; the Dolphin selectors are harmless in other apps). **End state** (needs a platform theme that appends instead of replaces - see qt6ct-independence.md option A): global = `shared.qss` only, Dolphin gets `dolphin-theme.qss` by flag. |
| 2 | QSS file shape | fully generated from `templates/*.in`; no hand edits | install the repo, `dolphin-tweaks init`, copy the colors (Debian's live conf values: see its handoff), `apply` |
| 3 | Color scheme | dedicated `dolphin-tweaks.colors` + `dolphinrc ColorScheme=` (single writer) | same; `bluegrey.colors` stays for other apps |
| 4 | Fixed deltas (button row, slider, tip border) | one set in `bin/dolphin-tweaks` (D_*), flat slider | Debian used D_BUTTON -3, gradient slider, tip border +30,30,33: pick the shared set and check one render visually |
| 5 | Arrow gap | `arrowgap` key (4) | set `arrowgap` to Debian's 6 in the conf if desired - no source difference any more |
| 6 | LD_PRELOAD scrubbing | in the shim (core.cpp) | nothing: Debian's constructor is now the shared one |
| 7 | Build | `shim/build.sh` (fetches matching Dolphin source, preflight) | needs Qt6 headers (`qt6-base-dev`, private headers) instead of the private sysroot |
| 8 | Patches | `patches/` (Breeze 6.7.5, KWidgetsAddons 6.30.0 kcapacitybar) | Debian's Breeze was 6.7.4; rebase the patch hunk-by-hunk |
| 9 | Config homes | conf in `~/.config/dolphin-tweaks/`, outputs in `~/.themes/dolphin-theme/` (Breeze reads that path) | same paths |
| 10 | Knomadic rows | one table + `dolphin-color.sh` | port the table only (prefs.js differs elsewhere) |
| 11 | Dead pieces | `dolphin-lines.qss`, old wrappers removed | delete `dolphin-lines.qss` + 13 old wrappers; `set-accent-color.sh` still hex-edits the dead file |
| 12 | Colors that currently differ on purpose | accent `5a3e8b`, sidebar `383840`, view `1c1c20`, window `2c2c31` | Debian: accent `623e8b`, sidebar `323239`, view `1d1d20` - these are plain conf values |
