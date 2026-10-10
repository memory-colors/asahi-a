#!/bin/bash
# topbar-switch.sh - cut over between Dash to Panel and Knomadic's own Top Bar (knomadic@blank.local, topbar/).
#   on     disable dash-to-panel@blank.local, set Knomadic 'topbar-enabled' true   -> LOG OUT/IN to load the new code
#   off    re-enable dash-to-panel@blank.local, set 'topbar-enabled' false         -> LOG OUT/IN
#   status show both
# NOTE 2026-10-07: dash-to-panel@blank.local was moved to ~/.local/share/gnome-shell/extensions-bak/ (not scanned by Extension Manager). To roll back: move it back into ../extensions/, then run this script with `off`.
# Dash to Panel stays installed (disabled) as the rollback until you delete it.
set -euo pipefail
D2P="dash-to-panel@blank.local"
SCHEMADIR="$HOME/.local/share/gnome-shell/extensions/knomadic@blank.local/schemas"
SCHEMA="org.gnome.shell.extensions.knomadic"
case "${1:-status}" in
on)
    gsettings --schemadir "$SCHEMADIR" set "$SCHEMA" topbar-enabled true
    gnome-extensions disable "$D2P"
    echo "Knomadic Top Bar ON, Dash to Panel disabled. Log out and back in." ;;
off)
    gsettings --schemadir "$SCHEMADIR" set "$SCHEMA" topbar-enabled false
    gnome-extensions enable "$D2P"
    echo "Dash to Panel back ON, Knomadic Top Bar off. Log out and back in." ;;
status)
    echo "Knomadic topbar-enabled: $(gsettings --schemadir "$SCHEMADIR" get "$SCHEMA" topbar-enabled)"
    echo "Dash to Panel: $(gnome-extensions info "$D2P" 2>/dev/null | grep -i 'state' || echo unknown)" ;;
*) echo "Usage: $0 on|off|status"; exit 1 ;;
esac
