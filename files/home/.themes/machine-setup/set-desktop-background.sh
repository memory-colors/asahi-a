#!/bin/bash
# set-desktop-background.sh - solid desktop background colour via gsettings (org.gnome.desktop.background).
# Also keeps the overview workspace-thumbnail fill (.workspace-thumbnails .workspace-thumbnail in Adwaita-custom gnome-shell.css) equal
# to it (shows after the next log out/in).
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
TCSS="${SHELL_CSS:-$HOME/.themes/Adwaita-custom/gnome-shell/gnome-shell.css}"
if [ -f "$TCSS" ]; then
    python3 - "$TCSS" "$NEW" <<'PYEOF'
import re, sys
p, new = sys.argv[1:3]
t = open(p).read()
t, n = re.subn(r'(^\.workspace-thumbnails \.workspace-thumbnail\s*\{[^}]*?background-color:\s*)#[0-9a-fA-F]{6}', r'\g<1>#' + new, t, count=1, flags=re.M)
if n: open(p, 'w').write(t)
else: print("  (thumbnail rule not found in css)", file=sys.stderr)
PYEOF
    echo "Overview workspace thumbnails -> #$NEW (log out and back in to apply)"
fi
