#!/bin/bash
# dolphin-view-color.sh - change Dolphin's file-list view background color.
#
# This lives ONLY in ~/.local/share/color-schemes/bluegrey.colors'
# [Colors:View] section (BackgroundNormal/BackgroundAlternate) - a value
# distinct from kdeglobals' own [Colors:View] (which is part of the general
# "dark background" role owned by master_black_background.sh). Dolphin uses
# bluegrey.colors specifically (dolphinrc: ColorScheme=bluegrey), so this
# section is the one that actually renders Dolphin's file-list background.
#
# CURRENT_HEX below is the known-current value, hardcoded and self-updating,
# following the same safe pattern as master_black_background.sh /
# set-titlebar-color.sh.
#
# Also syncs the Dolphin status bar and path bar to the same color.
#
# Usage: ./dolphin-view-color.sh <new-hex-color>
#   e.g. ./dolphin-view-color.sh 1e1e21

set -euo pipefail

CURRENT_HEX="1c1c20"

if [ "${1:-}" == "--get" ]; then
    echo "$CURRENT_HEX"
    exit 0
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new-hex-color>"
    echo "  e.g. $0 1e1e21"
    exit 1
fi

NEW_HEX="${1#\#}"
NEW_HEX="${NEW_HEX,,}"

if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$1' doesn't look like a valid 6-digit hex color."
    exit 1
fi

# Keep the status bar and path bar in sync with the view color (they keep their
# own scripts/rows, so they can still be set separately afterward). Runs even
# when the view color is unchanged, to re-align them.
sync_siblings() {
    local d; d="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    for s in dolphin-statusbar-color.sh dolphin-pathbar-color.sh; do
        if [ "$("$d/$s" --get)" != "$NEW_HEX" ]; then "$d/$s" "$NEW_HEX"; fi
    done
}

OLD_HEX="${CURRENT_HEX,,}"
COLORS="$HOME/.local/share/color-schemes/bluegrey.colors"

if [ "$OLD_HEX" == "$NEW_HEX" ]; then
    echo "Current color is already #$NEW_HEX - re-syncing status bar and path bar."
    sync_siblings
    exit 0
fi

if [ ! -f "$COLORS" ]; then
    echo "Error: $COLORS not found - is this the right machine?" >&2
    exit 1
fi

hex_to_dec() {
    local hex="$1"
    printf "%d,%d,%d" "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}
OLD_DEC=$(hex_to_dec "$OLD_HEX")
NEW_DEC=$(hex_to_dec "$NEW_HEX")

echo "Changing Dolphin view #$OLD_HEX ($OLD_DEC) -> #$NEW_HEX ($NEW_DEC)"
echo

BACKUP_SUFFIX=".bak-pre-${NEW_HEX}"
cp "$COLORS" "${COLORS}${BACKUP_SUFFIX}"

# Targeted: only the [Colors:View] section's BackgroundNormal/BackgroundAlternate,
# not a whole-file replace - other sections (e.g. ColorEffects:Inactive Color=)
# may legitimately share the same decimal triple for an unrelated purpose.
python3 - "$COLORS" "$OLD_DEC" "$NEW_DEC" <<'PYEOF'
import sys
path, old_dec, new_dec = sys.argv[1:4]
lines = open(path).readlines()
in_view = False
for i, line in enumerate(lines):
    s = line.strip()
    if s.startswith('['):
        in_view = (s == '[Colors:View]')
        continue
    if in_view and s.startswith(('BackgroundNormal=', 'BackgroundAlternate=')):
        key, val = line.rstrip('\n').split('=', 1)
        if val.strip() == old_dec:
            lines[i] = f"{key}={new_dec}\n"
open(path, 'w').writelines(lines)
PYEOF
echo "  dec updated (Colors:View only): $COLORS"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
sed -i "s/^CURRENT_HEX=\"${OLD_HEX}\"/CURRENT_HEX=\"${NEW_HEX}\"/" "$SCRIPT_PATH"
echo "  self-updated: CURRENT_HEX in $SCRIPT_PATH -> ${NEW_HEX}"

echo
sync_siblings

echo
echo "Done. Restart Dolphin to see the change."
