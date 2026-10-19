#!/bin/bash
# set-light-background.sh - the GTK "lighter grey application background" role (Knomadic: GTK Colors / Titlebars > Light Application Background):
# window_bg_color / sidebar_bg_color in the GTK3/GTK4 files below. The current value is read from gtk-4.0's window_bg_color, so it is safe to re-run.
#
# SCOPE (narrowed 2026-10-17): GTK only. It used to also rewrite the qt5ct/qt6ct palettes, kdeglobals, bluegrey.colors, kdeglobals2.colors and
# Konsole's DarkOneNuanced scheme by matching the old value; those are now generated (Qt look from the Thunar swatches by fm-tweaks) or retired
# (qt5ct/qt6ct), and no .bak-pre-* copies are left behind any more.
#
# Usage: ./set-light-background.sh <new-hex-color>
#        ./set-light-background.sh --get   (print current hex)

set -euo pipefail

GTK4_CSS="$HOME/.config/gtk-4.0/gtk.css"

get_current() {
    grep -oP '(?<=@define-color window_bg_color #)[0-9a-fA-F]{6}' "$GTK4_CSS" 2>/dev/null | head -1
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

if [ ! -f "$GTK4_CSS" ]; then
    echo "Error: $GTK4_CSS not found - can't detect current GTK color."
    exit 1
fi

OLD_GTK=$(get_current)
OLD_GTK="${OLD_GTK,,}"

if [ -z "$OLD_GTK" ]; then
    echo "Error: couldn't find current window_bg_color in $GTK4_CSS"
    exit 1
fi

if [ "$OLD_GTK" == "$NEW_HEX" ]; then
    echo "GTK side already #$NEW_HEX - nothing to do."
    exit 0
fi

echo "GTK light background: #$OLD_GTK -> #$NEW_HEX"
echo

GTK_FILES=(
    "$GTK4_CSS"
    "$HOME/.config/gtk-3.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-3.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-3.0/gtk-dark.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-4.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-4.0/gtk-dark.css"
)

for f in "${GTK_FILES[@]}"; do
    if [ -f "$f" ]; then
        python3 "$HOME/.themes/machine-setup/replace_color_skip_fg.py" hex "$f" "$OLD_GTK" "$NEW_HEX"
        echo "  gtk hex updated: $f"
    fi
done

echo
echo "Done. Restart GTK apps to see the change - some may glitch on a live config swap, just reopen them."
