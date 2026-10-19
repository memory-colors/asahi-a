#!/bin/bash
# Re-trust .desktop launchers so Thunar shows each launcher's own Icon= (it needs the file executable AND gio metadata::xfce-exe-checksum == sha256 of the file).
# Re-run after editing/adding launchers.  usage: trust-desktop-files_2026-10-18.sh [dir-or-file ...]   (default: ~/.local/share/applications)
[ $# -eq 0 ] && set -- "$HOME/.local/share/applications"
for a in "$@"; do
    if [ -d "$a" ]; then files=("$a"/*.desktop); else files=("$a"); fi
    for f in "${files[@]}"; do [ -f "$f" ] || continue; chmod +x "$f"; gio set -t string "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | cut -d' ' -f1)"; done
done
