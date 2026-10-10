#!/bin/bash
# master_black_background.sh - change the shared "near-black" background
# color (Konsole background, KDE Button/Header backgrounds, Qt palette
# Button role) across every file it lives in. Titlebar/window-decoration
# color is a separate role - see set-titlebar-color.sh.
#
# CURRENT_HEX below is the known-current value, hardcoded rather than
# auto-detected. An earlier version detected it live from
# qwhitesurgtkdecorations.conf, but that file can drift out of sync with
# the other files (e.g. a manual edit to just one file, a "straggler"
# left at an old value) - a false detection there would silently target
# the wrong value everywhere else. This script now updates its OWN
# CURRENT_HEX to the new value after every successful run, so it's still
# safe to re-run repeatedly - just always trust this file's own record of
# "current", not a live re-detection.
#
# Usage: ./master_black_background.sh <new-hex-color>
#   e.g. ./master_black_background.sh 18181a
#        ./master_black_background.sh "#18181a"

set -euo pipefail

CURRENT_HEX="1f1f24"

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

if [ "$OLD_HEX" == "$NEW_HEX" ]; then
    echo "Current color is already #$NEW_HEX - nothing to do."
    exit 0
fi

# hex -> decimal RGB, for KDE's .colors/kdeglobals/.colorscheme files
hex_to_dec() {
    local hex="$1"
    printf "%d,%d,%d" "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}
OLD_DEC=$(hex_to_dec "$OLD_HEX")
NEW_DEC=$(hex_to_dec "$NEW_HEX")

echo "Changing #$OLD_HEX ($OLD_DEC) -> #$NEW_HEX ($NEW_DEC)"
echo

# SCOPED edits (rewritten 2026-10-05 per the user's no-blanket-replace rule; ownership as ruled):
#   - GTK3/GTK4 css: whole-hex replace of the old value, EXCEPT inside comments and /* KNOMADIC: ... */ marked
#     blocks (text editor etc.). Includes headerbar_bg_color: single-pane GTK app titlebars stay DARK = this
#     role. (Split-app sidebar headers are the grey foreground role, a different value.)
#   - qt6ct / qt5ct palette files: ONLY the Button (1), Base (9) and AlternateBase (16) roles, by position.
#     qt5ct's colors/Gradience.conf (SMPlayer) stays excluded - use smplayer-view-color.sh.
#   - KDE color files: BackgroundNormal/BackgroundAlternate in [Colors:View|Button|Header] only, where equal to
#     the old value. NOT [Colors:Selection]/[ColorEffects:*]/Decoration keys, and bluegrey [Colors:View] is
#     Dolphin's file view (dolphin-view-color.sh) - handled below by an explicit exclusion.
#   - Konsole's color scheme is NOT touched (user handles it manually, 2026-10-05).
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CSS_FILES=(
    "$HOME/.config/gtk-3.0/gtk.css"
    "$HOME/.config/gtk-3.0/gtk-dark.css"
    "$HOME/.config/gtk-4.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-3.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-3.0/gtk-dark.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-4.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-4.0/gtk-dark.css"
)
python3 "$HERE/_scoped_replace.py" css "$OLD_HEX" "$NEW_HEX" "${CSS_FILES[@]}"
python3 "$HERE/_scoped_replace.py" palette "$OLD_HEX" "$NEW_HEX" 1,9,16 \
    "$HOME/.config/qt6ct/colors/Gradience.conf" "$HOME/.config/qt5ct/style-colors.conf"
python3 "$HERE/_scoped_replace.py" ini "$OLD_DEC" "$NEW_DEC" 'Colors:(View|Button|Header)' BackgroundNormal,BackgroundAlternate \
    "$HOME/.config/kdeglobals" "$HOME/.local/share/color-schemes/kdeglobals2.colors"
python3 "$HERE/_scoped_replace.py" ini "$OLD_DEC" "$NEW_DEC" 'Colors:(Button|Header)' BackgroundNormal,BackgroundAlternate \
    "$HOME/.local/share/color-schemes/bluegrey.colors"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
if [ -z "${NO_SELF_UPDATE:-}" ]; then   # set NO_SELF_UPDATE=1 when testing against a fake HOME
    sed -i "s/^CURRENT_HEX=\"${OLD_HEX}\"/CURRENT_HEX=\"${NEW_HEX}\"/" "$SCRIPT_PATH"
    echo "  self-updated: CURRENT_HEX in $SCRIPT_PATH -> ${NEW_HEX}"
fi

echo
echo "Done. Restart GTK/Qt apps (Dolphin, Konsole, GNOME Text Editor, etc.)"
echo "to see the change - some may glitch/crash on live config swap, just"
echo "reopen them."
