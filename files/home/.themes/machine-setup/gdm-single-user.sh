#!/bin/bash
# gdm-single-user.sh - install/remove the GDM-greeter extension that skips the user list when there is exactly one user.
# Source: ~/.themes/machine-setup/gdm-single-user@blank.local/ ; installed to /usr/share/gnome-shell/extensions/ and enabled for the
# greeter via /etc/dconf/db/gdm.d/10-gdm-single-user (org/gnome/shell enabled-extensions) + `dconf update`. Uses pkexec (password prompt).
# Takes effect at the next greeter start (log out). Recovery if the greeter misbehaves: Ctrl+Alt+F3 -> run `gdm-single-user.sh remove`.
# Usage: ./gdm-single-user.sh install | remove | status
set -euo pipefail
UUID="gdm-single-user@blank.local"
SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/$UUID"
DEST="/usr/share/gnome-shell/extensions/$UUID"
CONF="/etc/dconf/db/gdm.d/10-gdm-single-user"
case "${1:-}" in
install)
    [ -f "$SRC/extension.js" ] || { echo "Source $SRC missing" >&2; exit 1; }
    pkexec bash -c 'set -e; rm -rf "$2"; install -d -m 755 "$2"; install -m 644 "$1"/metadata.json "$1"/extension.js "$2"/; restorecon -R "$2" 2>/dev/null || true
        printf "[org/gnome/shell]\nenabled-extensions=[\x27%s\x27]\n" "$3" > "$4"; chmod 644 "$4"; restorecon "$4" 2>/dev/null || true; dconf update' _ "$SRC" "$DEST" "$UUID" "$CONF"
    echo "Installed. Log out to see the greeter change." ;;
remove)
    pkexec bash -c 'rm -rf "$1" "$2"; dconf update' _ "$DEST" "$CONF"
    echo "Removed." ;;
status)
    [ -d "$DEST" ] && echo "extension: installed" || echo "extension: not installed"
    [ -f "$CONF" ] && echo "dconf: enabled ($CONF)" || echo "dconf: not enabled" ;;
*) echo "Usage: $0 install|remove|status"; exit 1 ;;
esac
