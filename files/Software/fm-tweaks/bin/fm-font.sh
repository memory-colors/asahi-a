#!/bin/bash
# fm-font.sh font|mono --get|"<Pango font description>" - Knomadic's "Thunar" font rows. Stored in ~/.config/fm-fonts/thunar.conf (font=, mono=), read by thunar-fm at every start.
# Restart Thunar to apply. Defaults: the interface font Thunar has always used, and the system monospace font.
F=$HOME/.config/fm-fonts/thunar.conf
key=$1; val=$2
case $key in font|mono) ;; *) echo "usage: fm-font.sh font|mono --get|<font>" >&2; exit 2 ;; esac
cur=$(sed -n "s/^$key=//p" "$F" 2>/dev/null | head -1)
if [ -z "$cur" ]; then
    if [ "$key" = font ]; then cur='SF Pro Regular, 14'; else cur=$(gsettings get org.gnome.desktop.interface monospace-font-name 2>/dev/null | tr -d "'"); fi
fi
if [ "$val" = --get ] || [ -z "$val" ]; then echo "$cur"; exit 0; fi
mkdir -p "$(dirname "$F")"; touch "$F"
grep -v "^$key=" "$F" > "$F.new"; echo "$key=$val" >> "$F.new"; mv "$F.new" "$F"
