#!/usr/bin/env bash
# set-accent-color.sh <hex> - changes the system-wide accent color in one go:
# GTK4 (including this system's adw-gtk3-dark-paired custom pack), GTK3
# (theme root + personal override, both light/dark copies), the shared Qt
# QSS (Dolphin/Konsole/Gwenview menus), Dolphin's KDE color scheme
# (bluegrey.colors), and qt6ct's palette Highlight role.
#
# Built 2026-09-26 after a full day of manually tracking down every place
# this system's accent color actually lives - see ~/Software/asahi-setup-reference_2026-10-09.txt
# and the linux_theming memory for the history of how each of these was
# found. GTK4's own gtk.css hardcodes the resolved accent hex directly in
# ~130 places (not just the root @define-color) rather than using the
# variable everywhere, so this script does a literal find-current/replace-
# with-new across the whole file, not just the root definition - a
# variable-only approach silently misses most of it.
#
# GNOME's own org.gnome.desktop.interface accent-color setting only accepts
# a fixed named preset (blue/teal/green/yellow/orange/red/pink/purple/slate),
# not an arbitrary hex - there is no way to make it exactly match a custom
# color. It's set to the closest named preset as a best-effort for anything
# that only consults the portal setting, but the real, exact color everywhere
# else comes from the files below.
#
# Usage:
#   set-accent-color.sh --sync-decoration[-dry-run]   (align Decoration keys to the current accent only)
#   set-accent-color.sh              (interactive - prompts for a hex value)
#   set-accent-color.sh 623e8b
#   set-accent-color.sh '#623e8b'

set -euo pipefail

GTK4_CSS_PEEK="$HOME/.config/gtk-4.0/gtk.css"

if [ "${1:-}" == "--get" ]; then
    grep -oP '(?<=@define-color accent_bg_color #)[0-9a-fA-F]{6}' "$GTK4_CSS_PEEK" 2>/dev/null | head -1
    exit 0
fi

if [ "${1:-}" == "--sync-decoration" ] || [ "${1:-}" == "--sync-decoration-dry-run" ]; then
    CUR=$(grep -oP '(?<=@define-color accent_bg_color #)[0-9a-fA-F]{6}' "$GTK4_CSS_PEEK" | head -1)
    EXTRA=""; [ "${1:-}" == "--sync-decoration-dry-run" ] && EXTRA="--dry-run"
    echo "Aligning DecorationFocus/DecorationHover (kdeglobals + bluegrey.colors) to the accent #$CUR ..."
    python3 "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_accent_apply.py" "$CUR" "$CUR" --decoration-only $EXTRA
    exit 0
fi

if [ "$#" -eq 1 ]; then
    RAW_INPUT="$1"
else
    CURRENT_FOR_PROMPT=$(grep -oP '(?<=@define-color accent_bg_color #)[0-9a-fA-F]{6}' "$GTK4_CSS_PEEK" 2>/dev/null | head -1)
    if [ -n "$CURRENT_FOR_PROMPT" ]; then
        echo "Current system accent color: #${CURRENT_FOR_PROMPT,,}"
    fi
    read -r -p "Enter new accent color (hex, e.g. 623e8b or #623e8b): " RAW_INPUT
    if [ -z "$RAW_INPUT" ]; then
        echo "No color entered - aborting, nothing changed." >&2
        exit 1
    fi
fi

NEW_HEX="${RAW_INPUT#\#}"
NEW_HEX="${NEW_HEX,,}"
if [[ ! "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "'$RAW_INPUT' doesn't look like a 6-digit hex color." >&2
    exit 1
fi

GTK4_CSS="$HOME/.config/gtk-4.0/gtk.css"
if [ ! -f "$GTK4_CSS" ]; then
    echo "Can't find $GTK4_CSS - is this the right machine?" >&2
    exit 1
fi

CURRENT_HEX=$(grep -oP '(?<=@define-color accent_bg_color #)[0-9a-fA-F]{6}' "$GTK4_CSS" | head -1)
CURRENT_HEX="${CURRENT_HEX,,}"
if [ -z "$CURRENT_HEX" ]; then
    echo "Could not find the current accent_bg_color in $GTK4_CSS - aborting, nothing changed." >&2
    exit 1
fi

if [ "$CURRENT_HEX" = "$NEW_HEX" ]; then
    echo "Accent color is already #$NEW_HEX - nothing to do."
    exit 0
fi

hex_to_rgb() {
    local hex="$1"
    echo "$((16#${hex:0:2})),$((16#${hex:2:2})),$((16#${hex:4:2}))"
}
CURRENT_RGB=$(hex_to_rgb "$CURRENT_HEX")
NEW_RGB=$(hex_to_rgb "$NEW_HEX")

echo "Current accent: #$CURRENT_HEX (rgb $CURRENT_RGB)"
echo "New accent:     #$NEW_HEX (rgb $NEW_RGB)"
echo

# --- GTK3/GTK4 css, dolphin QSS menu rule, KDE color files: SCOPED edits (no blind sed) ---
#     css: skips comments + KNOMADIC marked blocks; QSS: one rule; color files: [section] key only,
#     and DecorationFocus/DecorationHover in every section follow the accent (user ruling 2026-10-05).
python3 "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_accent_apply.py" "$CURRENT_HEX" "$NEW_HEX"

# --- qt6ct palette Highlight role (index 12, positional - other roles can
#     share the same literal hex, so this must not be a blind string replace) ---
QT6CT="$HOME/.config/qt6ct/colors/Gradience.conf"
if [ -f "$QT6CT" ]; then
    echo "Updating qt6ct palette ($QT6CT)..."
    python3 - "$QT6CT" "$CURRENT_HEX" "$NEW_HEX" <<'PYEOF'
import sys
path, old_hex, new_hex = sys.argv[1:4]
old_val = "ff" + old_hex
new_val = "ff" + new_hex
lines = open(path).readlines()
for i, line in enumerate(lines):
    if "=" in line and "_colors" in line:
        key, val = line.split("=", 1)
        vals = val.strip().split(", ")
        if vals[12].lower() == old_val.lower():
            vals[12] = new_val
        lines[i] = key + "=" + ", ".join(vals) + "\n"
open(path, "w").writelines(lines)
PYEOF
fi

# --- GNOME's own accent-color gsetting (named presets only, best-effort) ---
declare -A PRESETS=(
    [blue]="3584e4" [teal]="2190a4" [green]="3a944a" [yellow]="c88800"
    [orange]="ed5b00" [red]="e62d42" [pink]="d56199" [purple]="9141ac"
    [slate]="6f8396"
)
closest_preset() {
    local target="$1" best="" best_dist=999999
    local tr=$((16#${target:0:2})) tg=$((16#${target:2:2})) tb=$((16#${target:4:2}))
    for name in "${!PRESETS[@]}"; do
        local ph="${PRESETS[$name]}"
        local pr=$((16#${ph:0:2})) pg=$((16#${ph:2:2})) pb=$((16#${ph:4:2}))
        local dist=$(( (tr-pr)*(tr-pr) + (tg-pg)*(tg-pg) + (tb-pb)*(tb-pb) ))
        if [ "$dist" -lt "$best_dist" ]; then best_dist=$dist; best=$name; fi
    done
    echo "$best"
}
PRESET=$(closest_preset "$NEW_HEX")
echo "Setting GNOME's accent-color gsetting to closest named preset: $PRESET (not an exact hex match - GNOME only supports named presets)"
gsettings set org.gnome.desktop.interface accent-color "$PRESET" 2>/dev/null || true

echo
echo "Done. GTK3/GTK4 apps and Dolphin/Konsole/Gwenview pick this up live or on"
echo "next launch. For Qt apps already running (qt6ct palette change), restart them."
