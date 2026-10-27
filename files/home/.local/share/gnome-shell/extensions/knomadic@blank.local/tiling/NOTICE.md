# Tiling Assistant (folded into Knomadic)

Source: Tiling Assistant, version 56 (extension 3733 on extensions.gnome.org), https://github.com/ubuntu/Tiling-Assistant
Copyright the Tiling Assistant authors, licensed GPL-2.0-or-later (see the header of extension.js).

Folded in 2026-10-24 so quarter tiling (drag a window to a screen corner) survives GNOME upgrades together with Knomadic.
Differences from upstream: no translations; the upstream prefs (prefs.js, src/prefs, src/ui, stylesheet.css) were added 2026-10-25 and open as sub-pages from Knomadic's Windows > Tiling group (prefs.js there is a helper class, binding code unchanged); upstream stylesheet.css is loaded by Knomadic's extension.js; it is
started and stopped by Knomadic's extension.js (`#startTiling`) through a dynamic import inside try/catch, with its own
schema in tiling/schemas (same schema id + dconf path as upstream, so existing values carry over).

Fixed configuration (set with gsettings, schema org.gnome.shell.extensions.tiling-assistant): every keybinding empty except
tile-left-half = <Alt><Super>Left and tile-right-half = <Alt><Super>Right; tiling popup, tile groups, raise-tile-group,
layout picker, layout examples, focus hint, alt-tab override off; gaps are Tiling Assistant's own (Knomadic's strut-based Window Gap was removed 2026-10-25), all editable from the prefs UI now.
