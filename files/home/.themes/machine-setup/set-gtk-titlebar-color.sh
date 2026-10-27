#!/bin/bash
# set-gtk-titlebar-color.sh <role> <hex|--get> - titlebar colours for GTK4/libadwaita windows, as anchor-marked blocks in ~/.config/gtk-4.0/gtk.css.
#   role gtk : every libadwaita headerbar (Settings, Files-style apps...) except the X11 frames and the apps that have their own block
#              (Knomadic: GTK Colors / Titlebars > Titlebar). Selector `window headerbar:not(.default-decoration)`, inserted BEFORE the Text Editor
#              block so the Text Editor's own (equal-specificity, later) block still wins.
#   role x11 : the titlebars mutter-x11-frames draws for X11/XWayland windows (SMPlayer, Synaptic...). All X11 windows share one helper, so this
#              cannot be per-app. Selector `headerbar.default-decoration`, appended last. The helper reads the CSS only when it starts: LOG OUT/IN.
#              (Knomadic: SMPlayer > Titlebar (X11 windows).)
# Until a block is written the colour follows the usual @define-color headerbar_bg_color, so nothing changes by itself. Blocks never touch the
# global tokens or other apps; delete a block (BEGIN..END) to go back to following. No backups are written.
#
# Usage: ./set-gtk-titlebar-color.sh gtk|x11 <new-hex-color>
#        ./set-gtk-titlebar-color.sh gtk|x11 --get   (print the current hex)

set -euo pipefail

ROLE="${1:-}"
ARG="${2:-}"
GTK4_CSS="$HOME/.config/gtk-4.0/gtk.css"

# role inactive: NO window buttons / header bar buttons, menus, search fields and title text = bar colour in INACTIVE windows, for every GTK app (user rule 2026-10-24). Own marked block at the end of gtk-4.0/gtk.css and gtk-3.0/gtk.css.
# The bar colour is the headerbar colour token; apps with their own titlebar block (Text Editor, X11 frames, the gtk role) repeat the title rule with their own hex.
if [ "$ROLE" == "inactive" ]; then
    python3 - "$GTK4_CSS" "$HOME/.config/gtk-3.0/gtk.css" <<'PYEOF'
import sys
B = '/* KNOMADIC: inactive-titlebar BEGIN - do not edit by hand, see set-gtk-titlebar-color.sh */'
E = '/* KNOMADIC: inactive-titlebar END */'
G4 = """headerbar windowcontrols button.close:backdrop,
headerbar windowcontrols button.maximize:backdrop,
headerbar windowcontrols button.minimize:backdrop,
headerbar:backdrop button,
headerbar:backdrop menubutton,
headerbar:backdrop splitbutton,
headerbar:backdrop entry,
headerbar:backdrop searchentry,
headerbar:backdrop viewswitcher,
headerbar:backdrop stackswitcher,
headerbar:backdrop dropdown,
headerbar:backdrop switch {
  opacity: 0;
}
headerbar:backdrop .title,
headerbar:backdrop .subtitle,
headerbar:backdrop windowtitle label {
  color: @headerbar_bg_color;
}
window .sidebar-pane headerbar:backdrop .title,
window .sidebar-pane headerbar:backdrop .subtitle,
window .sidebar-pane headerbar:backdrop windowtitle label {
  color: @sidebar_bg_color;
}"""
G3 = """headerbar:backdrop button,
headerbar:backdrop menubutton,
headerbar:backdrop entry,
headerbar:backdrop switch,
.titlebar:backdrop button,
.titlebar:backdrop menubutton,
.titlebar:backdrop entry {
  opacity: 0;
}
headerbar .icon.titlebutton,
.titlebar .icon.titlebutton {
  opacity: 0;
  min-width: 0;
  min-height: 0;
  margin: 0;
  padding: 0;
}
headerbar:backdrop,
.titlebar:backdrop:not(headerbar) {
  background-color: @headerbar_bg_color;
  background-image: none;
}
headerbar:backdrop .title,
headerbar:backdrop .subtitle,
.titlebar:backdrop .title,
.titlebar:backdrop .subtitle,
.default-decoration .title:backdrop,
.default-decoration .subtitle:backdrop,
headerbar.default-decoration:backdrop .title,
headerbar.default-decoration:backdrop .subtitle {
  color: @headerbar_bg_color;
}"""
for path, body in ((sys.argv[1], G4), (sys.argv[2], G3)):
    t = open(path).read()
    if B in t:
        i = t.index(B); j = t.index(E) + len(E)
        t = t[:i].rstrip('\n') + '\n' + t[j:].lstrip('\n') if t[j:].strip() else t[:i].rstrip('\n') + '\n'
    t = t.rstrip('\n') + '\n\n' + B + '\n' + body + '\n' + E + '\n'
    open(path, 'w').write(t)
    print('inactive-titlebar written:', path)
PYEOF
    exit 0
fi

case "$ROLE" in
    gtk) NAME="gtk-titlebar"
         SEL='window headerbar:not(.default-decoration),
window headerbar:not(.default-decoration):backdrop' ;;
    x11) NAME="x11-titlebar"
         SEL='headerbar.default-decoration,
headerbar.default-decoration:backdrop' ;;
    *) echo "Usage: $0 gtk|x11 <new-hex-color|--get>"; exit 1 ;;
esac

MARK_BEGIN="/* KNOMADIC: $NAME BEGIN - do not edit by hand, see set-gtk-titlebar-color.sh */"
MARK_END="/* KNOMADIC: $NAME END */"

get_block() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{f=1} f{print} $0==e{f=0}' "$GTK4_CSS" 2>/dev/null | grep -oP '(?<=background-color: #)[0-9a-fA-F]{6}' | head -1 || true
}

get_current() {
    local v
    v=$(get_block)
    if [ -z "$v" ] && [ "$ROLE" == "x11" ]; then   # x11 follows the gtk block until it has its own
        MARK_BEGIN="/* KNOMADIC: gtk-titlebar BEGIN - do not edit by hand, see set-gtk-titlebar-color.sh */"
        MARK_END="/* KNOMADIC: gtk-titlebar END */"
        v=$(get_block)
    fi
    if [ -z "$v" ]; then
        v=$(grep -oP '(?<=@define-color headerbar_bg_color #)[0-9a-fA-F]{6}' "$GTK4_CSS" 2>/dev/null | head -1 || true)
    fi
    echo "$v"
}

if [ "$ARG" == "--get" ]; then
    get_current
    exit 0
fi

NEW_HEX="${ARG#\#}"
NEW_HEX="${NEW_HEX,,}"

if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$ARG' doesn't look like a valid 6-digit hex color."
    exit 1
fi

if [ ! -f "$GTK4_CSS" ]; then
    echo "Error: $GTK4_CSS not found."
    exit 1
fi

# no line under the headerbar (active or inactive): border + libadwaita's inset shade shadow off.
# gtk role only: headers INSIDE a split-view sidebar pane (Settings, Tweaks...) stay transparent so the lighter sidebar colour shows through (libadwaita's own `.sidebar-pane headerbar` rule; the block above would otherwise out-rank it)
EXTRA=""
if [ "$ROLE" == "x11" ]; then
    EXTRA="
/* no window icon in the frame, active or inactive (VeraCrypt etc.): hidden and collapsed */
headerbar.default-decoration windowcontrols image.icon {
  opacity: 0;
  min-width: 0;
  min-height: 0;
  margin: 0;
  padding: 0;
  -gtk-icon-size: 0px;
}"
fi
if [ "$ROLE" == "gtk" ]; then
    EXTRA="
window .sidebar-pane headerbar:not(.default-decoration),
window .sidebar-pane headerbar:not(.default-decoration):backdrop {
  background-color: transparent;
}"
fi
# inactive window: the title text disappears into the bar (window buttons: see the `inactive` role)
TITLE_SEL=$(printf '%s\n' "$SEL" | grep -v ':backdrop$' | sed 's/,$//' | sed 's/$/:backdrop .title,/' ; printf '%s\n' "$SEL" | grep -v ':backdrop$' | sed 's/,$//' | sed 's/$/:backdrop .subtitle/')
BLOCK="$MARK_BEGIN
$SEL {
  background-color: #$NEW_HEX;
  border-bottom: none;
  box-shadow: none;
}
$TITLE_SEL {
  color: #$NEW_HEX;
}$EXTRA
$MARK_END"

python3 - "$GTK4_CSS" "$MARK_BEGIN" "$MARK_END" "$BLOCK" "$ROLE" <<'PYEOF'
import sys
path, mbegin, mend, block, role = sys.argv[1:6]
with open(path) as f:
    content = f.read()
if mbegin in content:
    start = content.index(mbegin)
    end = content.index(mend) + len(mend)
    content = content[:start] + block + content[end:]
    print("Updated existing %s block." % role)
else:
    anchor = "/* KNOMADIC: text-editor-titlebar BEGIN"
    if role == "gtk" and anchor in content:
        i = content.index(anchor)
        content = content[:i] + block + "\n\n" + content[i:]
    else:
        content = content.rstrip("\n") + "\n\n" + block + "\n"
    print("Added new %s block." % role)
with open(path, "w") as f:
    f.write(content)
PYEOF

echo "$ROLE titlebar -> #$NEW_HEX"
echo
if [ "$ROLE" == "x11" ]; then
    echo "Done. X11 window frames pick this up after the next login (mutter-x11-frames reads the CSS only at start)."
else
    echo "Done. Restart the GTK4/libadwaita apps to see the change."
fi
