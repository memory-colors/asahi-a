#!/bin/bash
# grey_foreground.sh - change the shared "lighter grey" role (window/sidebar background).
#
# SCOPED (rewritten 2026-10-05 per the user's ownership rulings; no blind value replace):
#   - GTK3/GTK4 css: whole-hex replace of the current window_bg_color value, EXCEPT inside comments,
#     /* KNOMADIC: ... */ marked blocks (e.g. the text editor) and `@define-color headerbar_*` lines
#     (single-pane GTK app titlebars stay dark = owned by master_black_background.sh). This DOES change the
#     sidebar-side header of split apps (Settings, Tweaks - where the traffic lights live): in gtk-4.0/gtk.css
#     those rules carry this same literal, by design.
#   - qt6ct palette: ONLY the Window role (index 10), by position.
#   - dolphin-theme.qss: ONLY the generic `QToolTip` background. The Dolphin sidebar (KFilePlacesView) is its
#     OWN role (dolphin-sideview-color.sh) and is no longer touched here.
#   - qt5ct (SMPlayer) is excluded - use smplayer-window-color.sh.
#
# Usage: ./grey_foreground.sh <new-hex-color>      ./grey_foreground.sh --get
set -euo pipefail

if [ "${1:-}" == "--get" ]; then
    grep -oP '(?<=@define-color window_bg_color #)[0-9a-fA-F]{6}' "$HOME/.config/gtk-4.0/gtk.css" 2>/dev/null | head -1
    exit 0
fi
[ $# -eq 1 ] || { echo "Usage: $0 <new-hex-color>"; exit 1; }
NEW_HEX="${1#\#}"; NEW_HEX="${NEW_HEX,,}"
[[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]] || { echo "Error: '$1' doesn't look like a valid 6-digit hex color." >&2; exit 1; }

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
GTK4_CSS="$HOME/.config/gtk-4.0/gtk.css"
[ -f "$GTK4_CSS" ] || { echo "Error: $GTK4_CSS not found." >&2; exit 1; }
OLD_HEX="$(grep -oP '(?<=@define-color window_bg_color #)[0-9a-fA-F]{6}' "$GTK4_CSS" | head -1)"; OLD_HEX="${OLD_HEX,,}"
[ -n "$OLD_HEX" ] || { echo "Error: couldn't find window_bg_color in $GTK4_CSS" >&2; exit 1; }
if [ "$OLD_HEX" == "$NEW_HEX" ]; then echo "Already #$NEW_HEX - nothing to do."; exit 0; fi
echo "Grey foreground: #$OLD_HEX -> #$NEW_HEX"

GTK_FILES=(
    "$GTK4_CSS"
    "$HOME/.config/gtk-3.0/gtk.css"
    "$HOME/.config/gtk-3.0/gtk-dark.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-3.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-3.0/gtk-dark.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-4.0/gtk.css"
    "$HOME/.themes/adw-gtk3-dark/gtk-4.0/gtk-dark.css"
)
python3 "$HERE/_scoped_replace.py" css "$OLD_HEX" "$NEW_HEX" --skip-token headerbar_bg_color,headerbar_backdrop_color "${GTK_FILES[@]}"
python3 "$HERE/_scoped_replace.py" palette "$OLD_HEX" "$NEW_HEX" 10 "$HOME/.config/qt6ct/colors/Gradience.conf"

QSS="$HOME/.themes/dolphin-theme/dolphin-theme.qss"
if [ -f "$QSS" ]; then
    CUR="$(python3 "$HERE/_qss_rule_edit.py" --get "$QSS" 'QToolTip' 'background-color')"
    if [ "$CUR" == "$OLD_HEX" ]; then
        cp "$QSS" "${QSS}.bak-pre-grey-${NEW_HEX}"
        python3 "$HERE/_qss_rule_edit.py" --set "$QSS" 'QToolTip' 'background-color' "$NEW_HEX"
    else
        echo "  QToolTip background is #${CUR:-?} (not the old grey) - left alone."
    fi
fi
echo
echo "Done. Restart GTK/Qt apps to see the change."
