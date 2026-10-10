#!/bin/bash
# dolphin-pathbar-color.sh - Dolphin's path (breadcrumb) bar background.
# Unlike the sidebar/status bar this is NOT a QSS color: KUrlNavigator paints itself and a stylesheet
# can't reach it. The patched breeze6.so (see ~/.themes/dolphin-breeze-patch/) reads it from
# ~/.themes/dolphin-theme/breeze-colors.conf (line `pathbar=#rrggbb`) once per Dolphin process.
# Restart Dolphin to apply.
#
# Usage: ./dolphin-pathbar-color.sh <new-hex-color>
#        ./dolphin-pathbar-color.sh --get
set -euo pipefail
CONF="${DOLPHIN_BREEZE_CONF:-$HOME/.themes/dolphin-theme/breeze-colors.conf}"
if [ "${1:-}" == "--get" ]; then
    grep -oP '^pathbar=#\K[0-9a-fA-F]{6}' "$CONF" 2>/dev/null | head -1 | tr 'A-F' 'a-f'; exit 0
fi
[ $# -eq 1 ] || { echo "Usage: $0 <new-hex-color>"; exit 1; }
NEW_HEX="${1#\#}"; NEW_HEX="${NEW_HEX,,}"
[[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]] || { echo "Error: '$1' is not a 6-digit hex color." >&2; exit 1; }
mkdir -p "$(dirname "$CONF")"
[ -f "$CONF" ] && cp "$CONF" "${CONF}.bak-pre-pathbar-${NEW_HEX}"
if grep -q '^pathbar=' "$CONF" 2>/dev/null; then sed -i "s/^pathbar=.*/pathbar=#${NEW_HEX}/" "$CONF"; else echo "pathbar=#${NEW_HEX}" >> "$CONF"; fi
echo "Dolphin path bar -> #$NEW_HEX. Restart Dolphin to see it."
