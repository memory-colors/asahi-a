#!/bin/bash
# set-titlebar-color.sh - change the singular top titlebar/window-decoration
# background color (the custom GTK/Qt-uniform titlebar overlay drawn for
# apps like Dolphin, GNOME Text Editor, etc.) via qwhitesurgtkdecorations.conf.
#
# This is deliberately separate from master_black_background.sh's general
# "near-black" role (Konsole background, KDE Button/Header backgrounds, Qt
# palette Button role). It is also NOT the same as GTK's headerbar_bg_color
# CSS token, which controls the libadwaita split-pane sidebar/header color
# (Settings, Tweaks) - a legitimately different, unrelated role that this
# script does not touch.
#
# CURRENT_HEX below is the known-current value, hardcoded rather than
# auto-detected, following the same safe pattern as master_black_background.sh
# - this script updates its OWN CURRENT_HEX to the new value after every
# successful run, so it's safe to re-run repeatedly.
#
# Usage: ./set-titlebar-color.sh <new-hex-color>
#   e.g. ./set-titlebar-color.sh 18181a
#        ./set-titlebar-color.sh "#18181a"

set -euo pipefail

CURRENT_HEX="161618"

if [ "${1:-}" == "--get" ]; then
    echo "$CURRENT_HEX"
    exit 0
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new-hex-color>"
    echo "  e.g. $0 18181a"
    exit 1
fi

NEW_HEX="${1#\#}"
NEW_HEX="${NEW_HEX,,}"

if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$1' doesn't look like a valid 6-digit hex color."
    exit 1
fi

OLD_HEX="${CURRENT_HEX,,}"
DECO_CONF="$HOME/.config/qwhitesurgtkdecorations.conf"

if [ "$OLD_HEX" == "$NEW_HEX" ]; then
    echo "Current color is already #$NEW_HEX - nothing to do."
    exit 0
fi

if [ ! -f "$DECO_CONF" ]; then
    echo "Error: $DECO_CONF not found - is this the right machine?" >&2
    exit 1
fi

echo "Changing titlebar #$OLD_HEX -> #$NEW_HEX"
echo

BACKUP_SUFFIX=".bak-pre-${NEW_HEX}"
cp "$DECO_CONF" "${DECO_CONF}${BACKUP_SUFFIX}"
sed -i "s/${OLD_HEX}/${NEW_HEX}/gI" "$DECO_CONF"
echo "  hex updated: $DECO_CONF"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
sed -i "s/^CURRENT_HEX=\"${OLD_HEX}\"/CURRENT_HEX=\"${NEW_HEX}\"/" "$SCRIPT_PATH"
echo "  self-updated: CURRENT_HEX in $SCRIPT_PATH -> ${NEW_HEX}"

echo
echo "Done. Restart GTK/Qt apps (Dolphin, Konsole, GNOME Text Editor, etc.)"
echo "to see the change - some may glitch/crash on live config swap, just"
echo "reopen them."
