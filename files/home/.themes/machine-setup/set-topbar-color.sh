#!/bin/bash
# set-topbar-color.sh - Knomadic Top Bar background color (gsettings key topbar-color of the Knomadic extension).
# Live: the extension watches the key. Usage: ./set-topbar-color.sh <hex>   |   ./set-topbar-color.sh --get
set -euo pipefail
SCHEMADIR="$HOME/.local/share/gnome-shell/extensions/knomadic@blank.local/schemas"
SCHEMA="org.gnome.shell.extensions.knomadic"
if [ "${1:-}" == "--get" ]; then
    gsettings --schemadir "$SCHEMADIR" get "$SCHEMA" topbar-color | tr -d "'#" | tr 'A-F' 'a-f'
    exit 0
fi
[ $# -eq 1 ] || { echo "Usage: $0 <new-hex-color> | --get"; exit 1; }
NEW="${1#\#}"; NEW="${NEW,,}"
[[ "$NEW" =~ ^[0-9a-f]{6}$ ]] || { echo "Error: '$1' is not a 6-digit hex color." >&2; exit 1; }
gsettings --schemadir "$SCHEMADIR" set "$SCHEMA" topbar-color "#$NEW"
echo "Top bar color -> #$NEW"
