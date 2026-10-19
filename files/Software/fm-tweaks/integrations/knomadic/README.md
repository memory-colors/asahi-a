# Knomadic integration

Knomadic (GNOME Shell extension, `~/.local/share/gnome-shell/extensions/knomadic@blank.local/prefs.js`) shows the colors as pick rows. All rows call
ONE script: `~/.themes/machine-setup/dolphin-color.sh` -> a symlink to `bin/dolphin-color.sh` (Knomadic runs `/bin/bash <script> <args> --get|<hex>`, so the
entry point has to be a shell script). The rows are a table in prefs.js:

```js
const DOLPHIN_COLOR_ROWS = [   // [label, key, fallback hex, group]
    ['Dolphin Sidebar', 'sidebar', '383840', systemGroup], ['Dolphin Main View', 'view', '1c1c20', systemGroup], ...
    ['Status Bar Text', 'statustext', 'dcdcdc', dolphinStatusGroup], ['Disk Usage Text', 'disktext', 'dcdcdc', dolphinStatusGroup],
];
for (const [label, key, hex, group] of DOLPHIN_COLOR_ROWS)
    group.add(makeColorPickRow(_(label), hex, 'dolphin-color.sh', [key]));
```
Keys: `dolphin-tweaks list`. Picking `view` also clears the `pathbar` / `statusbar` overrides (as before). The kinetic-scroll group is separate (INI-backed).
To add a color: add a KEYS entry in bin/dolphin-tweaks, use `{{key}}` in a template, add one table row here.
