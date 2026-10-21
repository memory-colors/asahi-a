# thunar/ - snapshot of the live Thunar setup (2026-10-16)

These are COPIES for version control; the live files are elsewhere and are NOT auto-synced (re-copy after changing them):

| here | live location |
|---|---|
| hooks.c | ~/.themes/fm-sample/hooks.c (build: `gcc -shared -fPIC -o hooks.so hooks.c $(pkg-config --cflags --libs glib-2.0 gio-2.0 gobject-2.0) /usr/lib64/libgtk-3.so.0 /usr/lib64/libcairo.so.2 /usr/lib64/libpango-1.0.so.0 -ldl`) |
| thunar-fm | ~/.local/bin/thunar-fm (launcher: private XDG_CONFIG_HOME, keyfile gsettings, fonts, LD_PRELOAD hooks.so) |
| fonts.conf | ~/.config/fm-fonts/fonts.conf (bold -> regular, Thunar only) |
| fm-menu-hide.txt | ~/.config/fm-menu-hide.txt (menus other than the main right-click menu) |
| uca.xml, accels.scm | ~/.config/Thunar/ (custom actions; keyboard shortcuts - edit accels only while Thunar is closed) |

The look itself is GENERATED: `bin/fm-tweaks apply` renders templates/thunar.css.in + thunar-user.css.in into ~/.themes/fm-sample/ from ~/.config/fm-tweaks/fm-tweaks.conf.
`bin/round-folder-icons` writes the rounded folder icons (user overlay of MacTahoe-nord-dark).
What hooks.c does: label overrides, Ctrl+Right/Ctrl+Shift+Right copy/move to the other split pane, Tab pane switch, Ctrl+T toolbar toggle, dot-files-last sort,
Shift+arrow range select with expandable folders, rounded/inset row highlight, and the 8-entry right-click menu (incl. "Menu >" borrowing the hidden menu bar).
Full story: the newest ~/Software/Claude/system-change-log_asahi_<date>.txt and the Thunar section of the linux_theming memory note.
