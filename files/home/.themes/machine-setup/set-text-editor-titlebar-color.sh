#!/bin/bash
# set-text-editor-titlebar-color.sh - gnome-text-editor's OWN titlebar/
# headerbar color, decoupled from every other titlebar/background role.
#
# gnome-text-editor is a libadwaita/GTK4 app whose root window carries the
# CSS class `.org-gnome-TextEditor` (confirmed by extracting the app's own
# embedded /org/gnome/TextEditor/style.css via `gresource extract
# /usr/bin/gnome-text-editor /org/gnome/TextEditor/style.css` - it uses
# `window.org-gnome-TextEditor ...` selectors throughout). An earlier
# version of this script targeted `editor-window` instead (a false lead -
# that string only exists in the binary as a source filename / internal
# struct name, not a registered CSS element name - confirmed it never
# matched anything, so no edit from that version ever visually took) - NOT
# a generic `headerbar`. Its headerbar normally just
# inherits GTK4's global `headerbar_bg_color` token, which is actually owned
# by master_black_background.sh's "Dark background" role (NOT
# set-titlebar-color.sh - that script only ever touches
# ~/.config/qwhitesurgtkdecorations.conf, the KDE/Qt window-decoration
# config, which a native libadwaita headerbar never reads).
#
# This script instead writes a dedicated, anchor-scoped
# `editor-window headerbar` block, appended to gtk-4.0/gtk.css between its
# own marker comments - never touches the global headerbar_bg_color token
# or any other app's headerbar, and is immune to master_black_background.sh
# or any grey-shift run overwriting it back.
#
# Usage: ./set-text-editor-titlebar-color.sh <new-hex-color>
#        ./set-text-editor-titlebar-color.sh --get   (print current hex, no changes)

set -euo pipefail

GTK4_CSS="$HOME/.config/gtk-4.0/gtk.css"
MARK_BEGIN="/* KNOMADIC: text-editor-titlebar BEGIN - do not edit by hand, see set-text-editor-titlebar-color.sh */"
MARK_END="/* KNOMADIC: text-editor-titlebar END */"

get_current() {
    awk "/^$(printf '%s' "$MARK_BEGIN" | sed 's/[.[\*^$/]/\\&/g')\$/,/^$(printf '%s' "$MARK_END" | sed 's/[.[\*^$/]/\\&/g')\$/" "$GTK4_CSS" 2>/dev/null \
        | grep -oP '(?<=background-color: #)[0-9a-fA-F]{6}' | head -1
}

if [ "${1:-}" == "--get" ]; then
    get_current
    exit 0
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new-hex-color>"
    exit 1
fi

NEW_HEX="${1#\#}"
NEW_HEX="${NEW_HEX,,}"

if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$1' doesn't look like a valid 6-digit hex color."
    exit 1
fi

if [ ! -f "$GTK4_CSS" ]; then
    echo "Error: $GTK4_CSS not found."
    exit 1
fi

cp "$GTK4_CSS" "${GTK4_CSS}.bak-pre-texteditor-titlebar-${NEW_HEX}"

BLOCK=$(cat <<EOF
$MARK_BEGIN
window.org-gnome-TextEditor headerbar,
window.org-gnome-TextEditor headerbar:backdrop {
  background-color: #$NEW_HEX;
  border-bottom: 1px solid mix(black,#$NEW_HEX,0.25);
}
$MARK_END
EOF
)

if grep -qF "$MARK_BEGIN" "$GTK4_CSS"; then
    # Replace the existing block between the markers.
    python3 - "$GTK4_CSS" "$MARK_BEGIN" "$MARK_END" "$BLOCK" <<'PYEOF'
import sys
path, mbegin, mend, block = sys.argv[1:5]
with open(path) as f:
    content = f.read()
start = content.index(mbegin)
end = content.index(mend) + len(mend)
content = content[:start] + block + content[end:]
with open(path, 'w') as f:
    f.write(content)
PYEOF
    echo "Updated existing text-editor titlebar block."
else
    printf '\n%s\n' "$BLOCK" >> "$GTK4_CSS"
    echo "Appended new text-editor titlebar block."
fi

echo "Text editor titlebar -> #$NEW_HEX"
echo
echo "Done. Restart gnome-text-editor to see the change."
