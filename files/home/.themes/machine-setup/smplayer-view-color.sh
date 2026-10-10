#!/bin/bash
# smplayer-view-color.sh - change SMPlayer's content/view background color
# (the Qt "Base" palette role, index 9 in qt5ct's positional color list).
#
# SMPlayer sets qt_style=qt5ct-style internally (see ~/.config/smplayer/
# smplayer.ini), which loads the qt5ct-style QStyle plugin DIRECTLY -
# independent of QT_QPA_PLATFORMTHEME (which is qt6ct system-wide here and
# has no matching Qt5-ABI plugin, so it does nothing for SMPlayer). That
# plugin reads qt5ct.conf's color_scheme_path
# (~/.config/qt5ct/colors/Gradience.conf) for its palette.
#
# Index 9 (Base) is the content/view background - kept SEPARATE from:
#   - index 10 (Window, general widget/dialog chrome) -> smplayer-window-color.sh
#   - master_black_background.sh's general "dark background" role, which no
#     longer touches qt5ct's Gradience.conf at all as of 2026-09-29.
#
# Only edits index 9 (Base) - positional, not a blind hex replace, since
# other indices in the same line can coincidentally share a hex value.
#
# CURRENT_HEX below is the known-current value, hardcoded and self-updating,
# following the same safe pattern as the other machine-setup color scripts.
#
# Usage: ./smplayer-view-color.sh <new-hex-color>
#   e.g. ./smplayer-view-color.sh 1b1b1d

set -euo pipefail

CURRENT_HEX="1b1b1d"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new-hex-color>"
    echo "  e.g. $0 1b1b1d"
    exit 1
fi

NEW_HEX="${1#\#}"
NEW_HEX="${NEW_HEX,,}"

if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$1' doesn't look like a valid 6-digit hex color."
    exit 1
fi

OLD_HEX="${CURRENT_HEX,,}"
GRADIENCE="$HOME/.config/qt5ct/colors/Gradience.conf"

if [ "$OLD_HEX" == "$NEW_HEX" ]; then
    echo "Current color is already #$NEW_HEX - nothing to do."
    exit 0
fi

if [ ! -f "$GRADIENCE" ]; then
    echo "Error: $GRADIENCE not found - is this the right machine?" >&2
    exit 1
fi

echo "Changing SMPlayer view background #$OLD_HEX -> #$NEW_HEX"
echo

BACKUP_SUFFIX=".bak-pre-${NEW_HEX}"
cp "$GRADIENCE" "${GRADIENCE}${BACKUP_SUFFIX}"

python3 - "$GRADIENCE" "$OLD_HEX" "$NEW_HEX" <<'PYEOF'
import sys
path, old_hex, new_hex = sys.argv[1:4]
old_val = "ff" + old_hex
new_val = "ff" + new_hex
lines = open(path).readlines()
changed = 0
for i, line in enumerate(lines):
    if "=" in line and "_colors" in line:
        key, val = line.split("=", 1)
        vals = val.strip().split(", ")
        if len(vals) > 9 and vals[9].lower() == old_val.lower():
            vals[9] = new_val
            lines[i] = key + "=" + ", ".join(vals) + "\n"
            changed += 1
open(path, "w").writelines(lines)
print(f"  Base role (index 9) updated in {changed} line(s): {path}")
PYEOF

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
sed -i "s/^CURRENT_HEX=\"${OLD_HEX}\"/CURRENT_HEX=\"${NEW_HEX}\"/" "$SCRIPT_PATH"
echo "  self-updated: CURRENT_HEX in $SCRIPT_PATH -> ${NEW_HEX}"

echo
echo "Done. Restart SMPlayer to see the change."
