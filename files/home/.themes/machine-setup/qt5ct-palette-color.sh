#!/bin/bash
# qt5ct-palette-color.sh - change one specific QPalette role's color in
# ~/.config/qt5ct/colors/Gradience.conf (SMPlayer's actual color source -
# it sets qt_style=qt5ct-style internally, bypassing QT_QPA_PLATFORMTHEME
# entirely). Updates active_colors/inactive_colors/disabled_colors together,
# keeping all three variants of a role in sync at the same color (a role
# picker shouldn't leave the disabled-state variant behind at some stale
# earlier value).
#
# Role -> array index mapping confirmed via a live "rainbow test" 2026-09-29
# (every one of the 21 positional slots set to a distinct color at once,
# SMPlayer hard-relaunched, visually matched) - see linux_theming memory for
# the full table and the reusable testing technique. The array follows
# Qt's own QPalette::ColorRole enum order.
#
# Confirmed roles/what they control in SMPlayer specifically:
#   window-text (0)      - main menu text
#   button (1)            - playlist title/buttons, radio slider buttons
#   base (9)               - playlist content/list area background
#   window (10)            - playlist main background, floating control bar bg
#   highlight (12)         - playlist selection bar, slider progress fill
#   highlighted-text (13)  - selected playlist text
#   link (14)               - normal (unselected) playlist text (unusual,
#                             but confirmed - not the "text" role)
#
# Auto-detects the CURRENT value at the target index (including its own
# alpha channel, which is NOT uniformly "ff" across all 21 slots - index 13
# is "dd" by default) rather than assuming a hardcoded prior value - more
# robust than the single-role scripts this generalizes
# (smplayer-window-color.sh / smplayer-view-color.sh, now superseded by
# role=window / role=base here but left on disk, unreferenced).
#
# Usage: ./qt5ct-palette-color.sh <role> <new-hex-color>
#   e.g. ./qt5ct-palette-color.sh window 1b1b1d

set -euo pipefail

declare -A ROLE_INDEX=(
    [window-text]=0
    [button]=1
    [base]=9
    [window]=10
    [highlight]=12
    [highlighted-text]=13
    [link]=14
)

if [ $# -lt 1 ]; then
    echo "Usage: $0 <role> <new-hex-color>"
    echo "  roles: ${!ROLE_INDEX[@]}"
    echo "  e.g. $0 window 1b1b1d"
    exit 1
fi

ROLE="$1"
if [ -z "${ROLE_INDEX[$ROLE]+x}" ]; then
    echo "Error: unknown role '$ROLE'. Valid roles: ${!ROLE_INDEX[@]}" >&2
    exit 1
fi
INDEX="${ROLE_INDEX[$ROLE]}"

if [ "${2:-}" == "--get" ]; then
    GRADIENCE="$HOME/.config/qt5ct/colors/Gradience.conf"
    python3 - "$GRADIENCE" "$INDEX" <<'PYEOF'
import sys
path, index = sys.argv[1], int(sys.argv[2])
for line in open(path):
    if line.startswith("active_colors="):
        vals = line.split("=", 1)[1].strip().split(", ")
        print(vals[index].lstrip("#")[2:8])
        break
PYEOF
    exit 0
fi

if [ $# -ne 2 ]; then
    echo "Usage: $0 <role> <new-hex-color>"
    echo "  roles: ${!ROLE_INDEX[@]}"
    echo "  e.g. $0 window 1b1b1d"
    exit 1
fi

NEW_HEX="${2#\#}"
NEW_HEX="${NEW_HEX,,}"

if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$2' doesn't look like a valid 6-digit hex color."
    exit 1
fi

GRADIENCE="$HOME/.config/qt5ct/colors/Gradience.conf"
if [ ! -f "$GRADIENCE" ]; then
    echo "Error: $GRADIENCE not found - is this the right machine?" >&2
    exit 1
fi

BACKUP_SUFFIX=".bak-pre-${ROLE}-${NEW_HEX}"
cp "$GRADIENCE" "${GRADIENCE}${BACKUP_SUFFIX}"

python3 - "$GRADIENCE" "$INDEX" "$NEW_HEX" "$ROLE" <<'PYEOF'
import sys
path, index, new_hex, role = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
lines = open(path).readlines()
changed = 0
old_seen = None
for i, line in enumerate(lines):
    if line.startswith("active_colors=") or line.startswith("inactive_colors=") or line.startswith("disabled_colors="):
        key, val = line.rstrip("\n").split("=", 1)
        vals = val.strip().split(", ")
        if len(vals) <= index:
            continue
        cur = vals[index].lstrip("#")
        alpha, rgb = cur[0:2], cur[2:8]
        old_seen = rgb
        if rgb.lower() == new_hex.lower():
            continue
        vals[index] = f"#{alpha}{new_hex}"
        lines[i] = key + "=" + ", ".join(vals) + "\n"
        changed += 1
if changed == 0:
    print(f"  {role} (index {index}) is already #{new_hex} - nothing to do.")
else:
    open(path, "w").writelines(lines)
    print(f"  {role} (index {index}): #{old_seen} -> #{new_hex} ({changed} line(s) updated)")
PYEOF

echo
echo "Done. Restart SMPlayer to see the change."
