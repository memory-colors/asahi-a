#!/bin/bash
# set-desktop-background.sh - solid desktop background colour via gsettings (org.gnome.desktop.background).
# Usage: set-desktop-background.sh --get | <hex>. Also forces a solid fill (no picture) so the colour is what shows.
set -euo pipefail
S=org.gnome.desktop.background
get() { gsettings get "$S" primary-color | tr -d "'#" | tr 'A-F' 'a-f'; }
[ "${1:-}" == "--get" ] && { get; exit 0; }
[ $# -eq 1 ] || { echo "Usage: $0 <new-hex-color>"; exit 1; }
NEW="${1#\#}"; NEW="${NEW,,}"
[[ "$NEW" =~ ^[0-9a-f]{6}$ ]] || { echo "Error: '$1' is not a 6-digit hex color." >&2; exit 1; }
gsettings set "$S" picture-uri none
gsettings set "$S" picture-uri-dark none
gsettings set "$S" color-shading-type solid
gsettings set "$S" secondary-color "#$NEW"
gsettings set "$S" primary-color "#$NEW"
echo "Desktop background -> #$NEW"
