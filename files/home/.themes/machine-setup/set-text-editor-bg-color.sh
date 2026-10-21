#!/bin/bash
# set-text-editor-bg-color.sh - gnome-text-editor's CONTENT background (the
# GtkSourceView canvas - what you're actually typing against).
#
# THIRD AND FINAL CORRECTION, 2026-10-04 - two earlier approaches both
# failed live-testing and were reverted:
#   1. Writing `window.*.background` rules to gtk-4.0/gtk.css - wrong,
#      that's window chrome, not the content canvas.
#   2. Editing GtkSourceView style-scheme XML files' `text`/
#      `background-pattern` colors in ~/.local/share/gtksourceview-5/styles/
#      (the binary links libgtksourceview-5.so.0), confirmed via the live
#      Preferences theme-picker thumbnails actually re-rendering with the
#      edited color). Even with the right file, the real editor canvas
#      STILL didn't change on a full, user-confirmed app restart.
#
# ROOT CAUSE, confirmed by reading ~/.config/gtk-4.0/gtk.css directly:
# a pre-existing, GLOBAL, UNSCOPED rule already present in that file -
#   textview { background-color: #1d1d20; }
#   textview > text { background-color: #1d1d20; }
# GtkSourceView is a GtkTextView subclass and keeps the CSS element name
# `textview` - this blanket rule, at user-stylesheet priority, wins over
# ANY GtkSourceStyleScheme-driven background for every textview in every
# GTK4 app on the system (confirmed by elimination: an isolated test that
# changed view_bg_color/card_bg_color/dialog_bg_color instead also had no
# effect - the actual paint comes from this `textview` rule specifically,
# not the libadwaita named-color tokens either). This rule isn't owned by
# any Knomadic script - it predates this investigation and presumably
# styles other apps' plain (non-GtkSourceView) textviews too, so it's left
# alone; this script instead adds a MORE SPECIFIC override.
#
# This script writes an anchor-marked block scoped to
# `window.org-gnome-TextEditor textview` / `> text` (the `.org-gnome-
# TextEditor` class confirmed via gnome-text-editor's own embedded
# /org/gnome/TextEditor/style.css, extracted with
# `gresource extract /usr/bin/gnome-text-editor /org/gnome/TextEditor/style.css`).
# A class+type descendant selector beats the bare `textview`/`textview >
# text` type selectors on specificity alone, so no !important is needed,
# and nothing else that uses plain `textview` elsewhere is touched.
#
# Usage: ./set-text-editor-bg-color.sh <new-hex-color>
#        ./set-text-editor-bg-color.sh --get   (print current hex, no changes)

set -euo pipefail

GTK4_CSS="$HOME/.config/gtk-4.0/gtk.css"
MARK_BEGIN="/* KNOMADIC: text-editor-bg BEGIN - do not edit by hand, see set-text-editor-bg-color.sh */"
MARK_END="/* KNOMADIC: text-editor-bg END */"

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


BLOCK=$(cat <<EOF
$MARK_BEGIN
window.org-gnome-TextEditor textview,
window.org-gnome-TextEditor textview > text {
  background-color: #$NEW_HEX;
}
$MARK_END
EOF
)

if grep -qF "$MARK_BEGIN" "$GTK4_CSS"; then
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
    echo "Updated existing text-editor background block."
else
    printf '\n%s\n' "$BLOCK" >> "$GTK4_CSS"
    echo "Appended new text-editor background block."
fi

echo "Text editor content background -> #$NEW_HEX"
echo
echo "Done. Fully quit (not just close the window) and restart gnome-text-editor to see the change."
