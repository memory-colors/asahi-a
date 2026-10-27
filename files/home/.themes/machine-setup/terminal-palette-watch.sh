#!/bin/bash
# Keeps Knomadic's Terminal background overrides when a palette is picked in Ptyxis' own preferences: on every change of the profile palette to something
# other than "knomadic", make that palette the new base (set-terminal-color.sh base <id>), which re-selects "knomadic" = that palette + the overridden backgrounds.
# Run by ~/.config/systemd/user/ptyxis-palette-watch.service.
S="$(dirname "$(readlink -f "$0")")/set-terminal-color.sh"
U=$(gsettings get org.gnome.Ptyxis default-profile-uuid | tr -d "'")
K="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$U/"
dconf watch "/org/gnome/Ptyxis/Profiles/$U/palette" | while read -r line; do
    id=$(gsettings get "$K" palette | tr -d "'")
    case "$id" in knomadic|"") continue ;; black-plum) id="Black Plum" ;; esac
    "$S" base "$id" >/dev/null 2>&1 || true
done
