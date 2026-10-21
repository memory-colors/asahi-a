# fm-tweaks

A personal look-and-feel layer for **Thunar** (GTK3 file manager) and the wrapped Qt apps (SMPlayer, Konsole, Ark, kcolorchooser, qView):
**one config file** is turned into every stylesheet / palette those apps load.

```
~/.config/fm-tweaks/fm-tweaks.conf      <- the ONLY file you edit (or: fm-tweaks set <key> <value>, or Knomadic's color rows -> bin/fm-color.sh)
        |  bin/fm-tweaks apply
        v
templates/thunar*.in    ->  ~/.themes/fm-sample/{gtk-3.0/gtk.css,user.css,gtk4.css}       (Thunar, launched by thunar/thunar-fm)
templates/shared.qss.in ->  ~/.themes/qt-fm/{qt-general,kcolorchooser}.qss                (rounded menus/tooltips for every wrapped Qt app)
                            ~/.config/fm-tweaks/qt-theme.conf, bluegrey.colors, kdeglobals [Colors:*]   (palette/font/icons, read by qt-shim/libqt-fm.so)
templates/smplayer.qss.in -> ~/.config/smplayer/themes/PapirusDark/style.qss + qt-theme-smplayer.conf  (SMPlayer's own palette, sm* keys)
```

## Quick start
```
bin/fm-tweaks init      # first time only: writes the conf with defaults (then edit it)
bin/fm-tweaks apply     # regenerate outputs; `status` shows drift, `list` shows every key
```
Restart Thunar / the Qt app to see changes.

## Layout
`bin/` fm-tweaks CLI, `fm-color.sh` / `fm-font.sh` (Knomadic entry points), `round-folder-icons`, `flat-mime-icons` |
`templates/` hand-edited sources of the generated files | `thunar/` snapshot of the live Thunar setup (hooks.c, thunar-fm launcher, accels, uca.xml; see thunar/README.md) |
`patches/` Thunar source patches for the private build (split focus, collision numbering) | `qt-shim/` libqt-fm.so source (palette/font/icons for wrapped Qt apps) |
`tools/` fm-newitem, fm-confirm, fm-drv.c, qt-shot.cpp (offscreen screenshot of any Qt6 app), gtk4-dialog-preview.js.
