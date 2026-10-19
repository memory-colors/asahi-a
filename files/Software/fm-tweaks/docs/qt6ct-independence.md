# Spike: depending less on qt6ct (investigation only, nothing changed)

## What we use qt6ct for (Asahi `~/.themes/qt6ct/qt6ct.conf`, `QT_QPA_PLATFORMTHEME=qt6ct` set in `~/.bashrc`)
| Feature | Value | Needed for |
|---|---|---|
| application palette | `custom_palette=true`, `Gradience.conf` (22 roles x active/inactive/disabled) | every Qt6 app's base colors (Dolphin: file names / tree text, now overridden in-process by the shim) |
| widget style | `style=Breeze` (patched build via `QT_PLUGIN_PATH=~/.themes/qt-plugins/qt6`) | the look of everything |
| icon theme | `icon_theme=MacTahoe-nord-dark` | all Qt6 apps |
| fonts | general `SF Pro Regular 13`, fixed `Iosevka Fixed 12` | all Qt6 apps |
| interface hints | single-click activate, `menus_have_icons=false`, `dialog_buttons_have_icons=1`, `toolbutton_style=4`, `wheel_scroll_lines=3`, `underline_shortcut`, `keyboard_scheme=2`, double-click interval, cursor flash | behavior |
| stylesheets | `@Invalid()` on Asahi (Debian: one global QSS) | Debian only |
Gaps already patched around: `libqt-noicons.so` (an LD_PRELOAD that stops menu icons, because the hint isn't honored everywhere) - a platform theme can answer that hint itself.

## Size of the thing to fork
Installed: `libqt6ct.so` (platform theme, ~70 KB), `libqt6ct-common.so` (config + palette reader, ~70 KB), `libqt6ct-style.so` (proxy style, ~70 KB), plus the `qt6ct` settings app (widgets UI, the bulk of the source). License BSD-2, upstream https://www.opencode.net/trialuser/qt6ct. The *runtime* part is small (a `QPlatformTheme` subclass: palette, fonts, `themeHint()`, icon theme name, plus the style proxy).

## Options
* **A. Knomadic-owned minimal platform theme** (a trimmed qt6ct fork, runtime only): `QPlatformTheme` reading one conf (palette/fonts/icon/hints/stylesheet) written by Knomadic's prefs; ships in the existing `QT_PLUGIN_PATH`; absorbs `libqt-noicons`; no settings UI to maintain (Knomadic is the UI). Removes the single point of failure and lets the stylesheet be set natively (`QApplication::setStyleSheet` from the theme), fixing the global-vs-per-app split. Cost: a small C++ plugin per Qt minor version/arch (same build story as the shim).
* **B. Dolphin-only, in-process** (shim sets palette/fonts/icons/QSS itself): already partly done (`text` palette). Doesn't cover other Qt6 apps.
* **C. Keep qt6ct**; risk: unmaintained upstream (the packaged build is a git snapshot `23a985f`, 2025-09-07).

## Recommendation
Do A after the repo restructuring settles; B-style in-process overrides stay for Dolphin-only items. First concrete step when approved: `dnf download --source qt6ct` (no -y), read `qt6ct/src/qt6ct-qtplugin/` (qt6ctplatformtheme.cpp) and `qt6ct-common/` to cut the fork to: palette loader, font/icon/hints getters, stylesheet application.
