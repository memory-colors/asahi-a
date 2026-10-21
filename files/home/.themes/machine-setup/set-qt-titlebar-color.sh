#!/bin/bash
# set-qt-titlebar-color.sh (Knomadic: Qt Apps > Titlebar) - titlebar of the NATIVE-WAYLAND Qt windows only (Konsole, Ark...: the Qt Wayland decoration
# plugin). It does NOT colour Thunar (fm-tweaks `titlebar`), SMPlayer / any X11 window (set-gtk-titlebar-color.sh x11), GTK4 apps (set-gtk-titlebar-color.sh gtk)
# or Text Editor (set-text-editor-titlebar-color.sh). Original header follows.
#
# The SINGULAR top titlebar / window-decoration
# background color, touching ONLY ~/.config/qwhitesurgtkdecorations.conf's
# BackgroundColor key.
#
# Split out from set-dark-background.sh (which used to also own this
# file) per the user's standing preference: the Qt titlebar tracks its OWN
# role, independent of the general dark background role.
#
# *** Do not confuse this with GTK's headerbar_bg_color token in gtk.css ***
# headerbar_bg_color (and its mix()-derived variants) is the libadwaita
# split-pane sidebar/header color used by apps like Settings/Tweaks - a
# DIFFERENT visual role from the singular top titlebar. The actual titlebar
# seen on native-Wayland Qt apps (Konsole, Ark...) is drawn entirely by this decoration
# config overlay. Never move headerbar_bg_color into this script.
#
# Usage: ./set-qt-titlebar-color.sh <new-hex-color>
#        ./set-qt-titlebar-color.sh --get   (print current hex, no changes)

set -euo pipefail

DECO_CONF="$HOME/.config/qwhitesurgtkdecorations.conf"

get_current() {
    grep -oP '(?<=BackgroundColor=#)[0-9a-fA-F]{6}' "$DECO_CONF" | head -1
}

if [ "${1:-}" == "--get" ]; then
    get_current
    exit 0
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new-hex-color>"
    exit 1
fi

NEW_HEX="${1#\#}"
NEW_HEX="${NEW_HEX,,}"

if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$1' doesn't look like a valid 6-digit hex color."
    exit 1
fi

if [ ! -f "$DECO_CONF" ]; then
    echo "Error: $DECO_CONF not found - can't detect current color."
    exit 1
fi

OLD_HEX=$(get_current)
OLD_HEX="${OLD_HEX,,}"

if [ -z "$OLD_HEX" ]; then
    echo "Error: couldn't find current BackgroundColor in $DECO_CONF"
    exit 1
fi

if [ "$OLD_HEX" == "$NEW_HEX" ]; then
    echo "Current color is already #$NEW_HEX - nothing to do."
    exit 0
fi

sed -i "s/BackgroundColor=#${OLD_HEX}/BackgroundColor=#${NEW_HEX}/I" "$DECO_CONF"
echo "Titlebar: #$OLD_HEX -> #$NEW_HEX"
echo "  updated: $DECO_CONF"
echo
echo "Done. Restart Qt apps (Konsole, Ark) to see the change."
