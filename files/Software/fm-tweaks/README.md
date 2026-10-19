# fm-tweaks

> **2026-10-16: Dolphin was retired in favour of Thunar.** Tag `dolphin-reference-2026-10-16` is the last Dolphin-only state (generator, QSS/scheme templates, kinetic-scroll shim, Breeze/KWidgetsAddons/Dolphin patches, docs). This repo now also generates the Thunar look (`templates/thunar*.in`, `thunar/`). To revive Dolphin: `git checkout dolphin-reference-2026-10-16`.


A personal look-and-feel layer for **stock Dolphin** (KDE file manager): nothing in Dolphin is patched on disk. A small `LD_PRELOAD` shim changes how
a few things are drawn, a generator turns **one config file** into the QSS / color scheme Dolphin loads, and a launcher ties it together.

```
~/.config/fm-tweaks/fm-tweaks.conf      <- the ONLY file you edit (or: fm-tweaks set <key> <value>, or Knomadic's color rows)
        |  bin/fm-tweaks apply   (also runs at every launch)
        v
templates/*.in  ->  <out>/dolphin-theme.qss   (shared.qss + dolphin.qss)   loaded with -stylesheet
                    <out>/shared.qss           (menus + tooltips; may also be loaded globally)
                    <out>/breeze-colors.conf   (runtime values for the patched Breeze and the shim)
                    ~/.local/share/color-schemes/dolphin-tweaks.colors + dolphinrc ColorScheme=
bin/dolphin-launch  ->  dolphin  (+ shim/libfm-tweaks.so preloaded)
```
`<out>` = `$FM_TWEAKS_OUT` or `~/.themes/dolphin-theme` (the patched Breeze reads that path).

## Quick start
```
shim/build.sh --install                 # builds against the INSTALLED Dolphin version (+ preflight), installs the .so
bin/fm-tweaks init                 # first time only: writes the conf with defaults (then edit it)
bin/fm-tweaks apply                # regenerate outputs; `status` shows drift, `list` shows every key
.desktop Exec=<repo>/bin/dolphin-launch %u
GRAB_SO=<built tools/grab.so> tests/verify.sh   # health check
```

## Tweak catalog (symptom -> mechanism -> where to change it)
| Tweak | How it's done | Config |
|---|---|---|
| Chevron expand arrows, tighter indent | shim `arrows.cpp` redefines `drawSiblingsInformation` / `updateExpansionArea` (a stylesheet makes stock Dolphin draw no arrows at all) | `arrowgap` |
| Kinetic touchpad scrolling (frame-synced glide) | shim `kinetic.cpp` hooks `KItemListContainer::wheelEvent` | Knomadic > Gestures (INI `~/.config/dolphin-kinetic-scroll.conf`); `DOLPHIN_KINETIC=0` disables |
| No alternate-row stripes | `items.cpp`: `setAlternateBackground` does nothing | - |
| Same background in both split panes | `panes.cpp`: restore the viewport alpha after `DolphinView::updatePalette` | - |
| Inactive split pane dimmed, never shows selection (delete-the-wrong-file safety) | `panes.cpp`: text/icons/header/arrows/status bar faded, `m_selected`/`m_current` cleared while painting | `inactivetext` |
| Hidden (dot) files look like normal ones | `items.cpp` / `panes.cpp` mask `m_isHidden` | - |
| Rounded ends on the row highlight (also where a narrow pane / split-view edge cuts it off) | `items.cpp`: stock highlight rendered to a scratch image and masked to the visible part of the row with rounded corners | `edgeradius` (px, both ends; 0 = stock) |
| Flat hover (no outline) | `items.cpp`: render hover into a scratch image, clamp alpha | - |
| URL bar edit mode uniform fill | `urlbar.cpp`: pre-fill with `pathbar` before `KUrlNavigator::paintEvent` | `pathbar` |
| Colors (sidebar, view, accent, panels, menus/tooltips, ...) | generated QSS + color scheme (see docs/color-map.md for which source drives which pixel) | `[colors]`, `[overrides]` |
| Text colors (general, sidebar, buttons/headers/menus, URL, status bar, disk text) | QSS rules + color scheme + shim replacing Text/WindowText in Dolphin's own palette | `[text]` |
| Rounded menus / tooltips / Open With dialog colors | `templates/shared.qss.in` | `tooltip` |
| EXPERIMENT: row pixmap cache for scrolling (A/B) | `panes.cpp`: `DolphinView` rows get `DeviceCoordinateCache` when `DOLPHIN_ROWCACHE=1` (default off); null-widget paint into the cache is patched | env only: `DOLPHIN_ROWCACHE=1 bin/dolphin-launch` |
| Flat disk-usage bar, zoom slider | patched KWidgetsAddons (`patches/`) + QSS | `view`, `accent` |

## Layout
`bin/` CLI + launcher + the one Knomadic entry point (`dolphin-color.sh`) | `templates/` hand-edited sources of the generated files | `shim/` C++ (common.h = hook macro,
core.cpp = runtime conf + version gate, one file per feature group) + `build.sh` | `patches/` Breeze, KWidgetsAddons, source patch for a future self-built Dolphin |
`integrations/knomadic/` the prefs rows | `tests/` verify.sh, render.sh + compare.py | `tools/` grab.cpp (test helper), dye-harness (the Debian color-source probe) | `docs/`.

## Safety properties
* The shim's layout-dependent hooks run **only on tested Dolphin versions** (`DT_TESTED_VERSIONS`, set by build.sh); on any other version they pass through to stock behavior and print one line on stderr. `FM_TWEAKS_FORCE=1` overrides.
* Every hook null-checks the original it wraps; the preload scrubs itself from child processes.
* `build.sh` preflight and `tests/verify.sh` check that each hooked symbol exists in the installed Dolphin libraries and is actually bound at runtime (a wrong mangled name builds fine and hooks nothing).

## Docs
`docs/color-map.md` (what drives which color) | `docs/gotchas.md` (mistakes already paid for) | `docs/debian-convergence.md` (what differed between the two machines and how to align them) |
`docs/qt6ct-independence.md` (spike: replacing qt6ct) | `docs/packaging-and-macos.md` (future).
