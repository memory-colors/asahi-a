import Adw from 'gi://Adw';
import Gio from 'gi://Gio';

import { ExtensionPreferences, gettext as _ } from
    'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

export default class CustomGesturesPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        const page = new Adw.PreferencesPage({
            title: _('General'),
            icon_name: 'input-touchpad-symbolic',
        });
        window.add(page);

        const group = new Adw.PreferencesGroup({
            title: _('Simulated keyboard shortcuts'),
            description: _('These must match real shortcuts already configured elsewhere - ' +
                'this extension doesn\'t create the shortcuts, it simulates pressing them. ' +
                'GTK accelerator format, e.g. "<Control><Shift>t".'),
        });
        page.add(group);

        const rows = [
            ['dolphin-split-view-accelerator', _('Dolphin split view'),
                _('Must match Dolphin\'s own "Split View" shortcut (Settings > Configure Shortcuts)')],
            ['tile-left-accelerator', _('Tile window left (default fallback)'),
                _('Must match this system\'s real tile-left keybinding')],
            ['tile-right-accelerator', _('Tile window right (default fallback)'),
                _('Must match this system\'s real tile-right keybinding')],
        ];

        for (const [key, title, subtitle] of rows) {
            const row = new Adw.EntryRow({
                title,
            });
            settings.bind(key, row, 'text', Gio.SettingsBindFlags.DEFAULT);
            group.add(row);

            if (subtitle) {
                const hint = new Adw.ActionRow({
                    subtitle,
                    sensitive: false,
                });
                group.add(hint);
            }
        }
    }
}
