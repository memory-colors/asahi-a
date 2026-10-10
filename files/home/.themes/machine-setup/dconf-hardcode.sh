#!/bin/bash
# dconf-hardcode.sh - ONE-TIME write of every GNOME Tweaks setting that has no GUI in Knomadic (2026-10-09).
# Knomadic > Interface keeps only: Interface Font, Monospace Font, Scaling Factor, Cursor, Icons, Gtk3 theme, Keyboard Layout Options.
# Everything below is pinned to the values in use on this machine when the script was written; re-running re-asserts them
# (idempotent, never run automatically). Edit a value here and re-run to change it. Values are GVariant text as printed by `gsettings get`.
# Not covered (not dconf): Tweaks' startup applications (~/.config/autostart), gtk settings.ini dark flag (already in gtk-3.0/settings.ini).
# Debian: wallpaper URIs and button-layout may need adjusting; sound theme name differs by distro.
set -u
set() { gsettings set "$1" "$2" "$3" 2>/dev/null && echo "ok   $1 $2" || echo "FAIL $1 $2"; }

set org.gnome.desktop.interface document-font-name "'SF Pro Medium, weight=510 14'"
set org.gnome.desktop.interface font-hinting "'slight'"
set org.gnome.desktop.interface font-antialiasing "'grayscale'"
set org.gnome.desktop.interface gtk-enable-primary-paste 'true'
set org.gnome.desktop.interface gtk-key-theme "'Default'"
set org.gnome.desktop.interface color-scheme "'prefer-dark'"
set org.gnome.desktop.wm.preferences button-layout "'close,minimize,maximize:'"
set org.gnome.desktop.wm.preferences action-double-click-titlebar "'toggle-maximize'"
set org.gnome.desktop.wm.preferences action-middle-click-titlebar "'none'"
set org.gnome.desktop.wm.preferences action-right-click-titlebar "'menu'"
set org.gnome.desktop.wm.preferences mouse-button-modifier "'<Super>'"
set org.gnome.desktop.wm.preferences resize-with-right-button 'false'
set org.gnome.desktop.wm.preferences focus-mode "'sloppy'"
set org.gnome.desktop.wm.preferences auto-raise 'true'
set org.gnome.mutter attach-modal-dialogs 'true'
set org.gnome.mutter center-new-windows 'false'
set org.gnome.mutter overlay-key "'Super'"
set org.gnome.desktop.input-sources show-all-sources 'true'
set org.gnome.desktop.sound theme-name "'freedesktop'"
set org.gnome.desktop.peripherals.touchpad click-method "'fingers'"
set org.gnome.desktop.peripherals.touchpad accel-profile "'default'"
set org.gnome.desktop.peripherals.mouse accel-profile "'default'"
set org.gnome.desktop.peripherals.pointingstick accel-profile "'default'"
set org.gnome.desktop.peripherals.pointingstick scroll-method "'default'"
set org.gnome.desktop.background picture-uri "'none'"
set org.gnome.desktop.background picture-uri-dark "'none'"
set org.gnome.desktop.background picture-options "'zoom'"
