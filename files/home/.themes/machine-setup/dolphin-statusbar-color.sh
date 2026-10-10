#!/bin/bash
# dolphin-statusbar-color.sh - Dolphin status bar (custom DolphinStatusBar widget, not QStatusBar) background
# Anchor-scoped (never a file-wide hex replace) edit of the `DolphinStatusBar, DolphinStatusBar QLabel` rule's
# `background` in ~/.themes/dolphin-theme/dolphin-theme.qss via _qss_rule_edit.py.
# Ported from the Debian setup, adapted to Asahi's single QSS file. Restart Dolphin to apply.
#
# Usage: ./dolphin-statusbar-color.sh <new-hex-color>
#        ./dolphin-statusbar-color.sh --get
set -euo pipefail
QSS="${DOLPHIN_QSS:-$HOME/.themes/dolphin-theme/dolphin-theme.qss}"
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SEL='DolphinStatusBar, DolphinStatusBar QLabel'
PROP='background'
if [ "${1:-}" == "--get" ]; then python3 "$HERE/_qss_rule_edit.py" --get "$QSS" "$SEL" "$PROP"; exit 0; fi
[ $# -eq 1 ] || { echo "Usage: $0 <new-hex-color>"; exit 1; }
NEW_HEX="${1#\#}"; NEW_HEX="${NEW_HEX,,}"
[[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]] || { echo "Error: '$1' is not a 6-digit hex color." >&2; exit 1; }
[ -f "$QSS" ] || { echo "Error: $QSS not found." >&2; exit 1; }
OLD="$(python3 "$HERE/_qss_rule_edit.py" --get "$QSS" "$SEL" "$PROP")"
[ -n "$OLD" ] || { echo "Error: couldn't find the $SEL rule in $QSS" >&2; exit 1; }
[ "$OLD" == "$NEW_HEX" ] && { echo "Already #$NEW_HEX - nothing to do."; exit 0; }
cp "$QSS" "${QSS}.bak-pre-dolphin-statusbar-$NEW_HEX"
python3 "$HERE/_qss_rule_edit.py" --set "$QSS" "$SEL" "$PROP" "$NEW_HEX"
echo "Done. Restart Dolphin to see the change."
