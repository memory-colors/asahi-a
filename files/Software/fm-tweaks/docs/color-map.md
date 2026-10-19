# What drives which color (Dolphin 26.08.x + patched Breeze)

Found on Debian with the dye harness (`tools/dye-harness`: render the real Dolphin offscreen on a throwaway HOME, give every color role a unique dye, count pixels
per role). 252 roles were dyed; the table is the result. Asahi's files were checked against it by hand (same Dolphin line); the map is version dependent
(Breeze 6.7.x, Dolphin 26.08.x), so re-run the harness after a major Breeze/Dolphin change.

| Element | Source (and the dolphin-tweaks key) |
|---|---|
| file-view background | scheme `[Colors:View] BackgroundNormal` (`view`) |
| Folders tree, Information panel, menu bar / toolbar strip | scheme `[Colors:Window] BackgroundNormal` (`window`); the toolbar follows `[Colors:Header]` if that section exists |
| column-header row bg / its text, QMenu item text | scheme `[Colors:Button] BackgroundNormal` (`view` - 6,6,8) / `ForegroundNormal` (`buttontext`) |
| accent: selection fill, hover tint, hover outline, focus ring, disk bars | scheme `[Colors:Selection] BackgroundNormal` (`accent`); focus ring = lighter(110) of it |
| Places text, breadcrumb text, "N items selected" | scheme `[Colors:View] ForegroundNormal`; Places and breadcrumb are overridden by QSS (`sidebartext`, `urltext`) |
| Information-panel labels, status-bar text | scheme `[Colors:Window] ForegroundNormal` (`text`); status bar labels overridden by QSS (`statustext`) |
| file names + selected-row detail text, Folders-tree labels | application palette Text / WindowText: the shim replaces them in Dolphin's process (`text`); stock source is the qt6ct palette `Gradience.conf` |
| Places sidebar background | QSS `KFilePlacesView { background }` only (palette ignored) (`sidebar`) |
| status bar background | QSS `DolphinStatusBar, DolphinStatusBar QLabel` (`statusbar`, follows `view`) |
| zoom slider groove / fill / handle | QSS `DolphinStatusBar QSlider::groove / sub-page / handle` (`view`-derived / `accent` / `view`-derived) |
| context-menu selected item, tooltip bg + border, menu bg, Open With dialog | QSS `QMenu::item:selected`, `QToolTip`, `QMenu`, `KOpenWithDialog` (`accent`, `tooltip`) |
| path (breadcrumb) bar background | `breeze-colors.conf pathbar=` read by the patched Breeze (breadcrumb mode only); edit mode = shim `urlbar.cpp` (`pathbar`) |
| disk-usage text ("x GiB free") | QSS `StatusBarSpaceInfo QToolButton { color }` (`disktext`) - it is a QToolButton, not KCapacityBar's text |

**Dead / irrelevant (zero pixels):** kdeglobals `[Colors:*]` (even with no ColorScheme Dolphin falls back to stock Breeze Light), the `DolphinUrlNavigator` QSS
rule on a qt6ct-global-QSS machine, all `Decoration*` roles, `BackgroundAlternate`, `Complementary`, qt6ct palette backgrounds/Highlight. Konsole's terminal
color is Konsole's own profile.
**`-stylesheet`:** works only where no global QSS replaces it (Asahi: qt6ct has no `stylesheets=`); on a machine with a global qt6ct QSS the per-app flag is ignored,
so put `<out>/dolphin-theme.qss` (or shared.qss + dolphin.qss) there instead - see debian-convergence.md.
