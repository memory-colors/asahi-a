#!/bin/bash
# post-update-check.sh - report-only: did a package update undo the theme work?
#   GDM gresource patched? .orig stale? build tools present? Thunar private build stamp? extension shell-version?
#   Run by hand, or at login via ~/.config/autostart/post-update-check.desktop (--login: notify only on problems).
# Usage: ./post-update-check.sh [--login]
GRES=/usr/share/gnome-shell/gnome-shell-theme.gresource
problems=()
add() { problems+=("$1"); }

# GDM resource: stock (-st-accent-color still present) = update wiped the patch
state=$(python3 -I - "$GRES" <<'PY'
import sys, gi
gi.require_version('Gio','2.0')
from gi.repository import Gio
r = Gio.Resource.load(sys.argv[1]); r._register()
t = bytes(Gio.resources_lookup_data('/org/gnome/shell/theme/gnome-shell-dark.css',0).get_data()).decode()
print('stock' if '-st-accent-color' in t else 'patched')
PY
)
if [ "$state" == stock ]; then
    add "GDM login theme is STOCK (update overwrote it): ~/.themes/machine-setup/set-shell-accent-color.sh --gdm"
    if [ -f "$GRES.orig" ] && ! cmp -s "$GRES" "$GRES.orig"; then
        add ".orig differs from the new stock gresource (stale); refresh BEFORE --gdm: sudo cp -a $GRES $GRES.orig"
    fi
fi
command -v glib-compile-resources >/dev/null || add "glib2-devel missing (GDM rebuild + gresource CLI): sudo dnf install glib2-devel"

# Thunar private build
stamp=$(cat ~/.local/libexec/thunar-fm/built-for-package-version 2>/dev/null)
cur=$(rpm -q --qf '%{VERSION}-%{RELEASE}' Thunar 2>/dev/null)
[ -n "$stamp" ] && [ "$stamp" != "$cur" ] && add "Thunar updated ($stamp -> $cur): thunar-fm now falls back to stock; rebuild the private build"

# Extensions vs running shell major
major=$(rpm -q --qf '%{VERSION}' gnome-shell | cut -d. -f1)
for m in ~/.local/share/gnome-shell/extensions/*/metadata.json; do
    python3 -I - "$m" "$major" <<'PY' || add "extension $(basename "$(dirname "$m")") does not list shell-version $major"
import json, sys
v = json.load(open(sys.argv[1])).get('shell-version', [])
sys.exit(0 if any(x.split('.')[0] == sys.argv[2] for x in v) else 1)
PY
done

if [ ${#problems[@]} -eq 0 ]; then
    [ "$1" == --login ] || echo "OK: gnome-shell $(rpm -q --qf '%{VERSION}' gnome-shell), GDM patched, no theme issues found."
    exit 0
fi
printf '%s\n' "${problems[@]}"
[ "$1" == --login ] && command -v notify-send >/dev/null && notify-send -u normal "Theme check after update" "$(printf '%s\n' "${problems[@]}")"
exit 1
