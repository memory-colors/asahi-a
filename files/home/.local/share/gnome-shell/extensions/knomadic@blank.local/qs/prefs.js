// Menu Bar prefs for the merged Quick Settings / Date Menu layout (runtime: qs/quickSettings.js).
// One reorder-and-hide dialog, reused for quick toggles, system indicators and the bottom-row items.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';
import { gettext as _ } from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

const TOGGLES = [
    ['NMWiredToggle', 'Wired'], ['NMWirelessToggle', 'Wi-Fi'], ['NMModemToggle', 'Mobile Network'],
    ['NMBluetoothToggle', 'Bluetooth (NetworkManager)'], ['NMVpnToggle', 'VPN'], ['BluetoothToggle', 'Bluetooth'],
    ['PowerProfilesToggle', 'Power Mode'], ['NightLightToggle', 'Night Light'], ['DarkModeToggle', 'Dark Style'],
    ['KeyboardBrightnessToggle', 'Keyboard Backlight'], ['RfkillToggle', 'Airplane Mode'], ['RotationToggle', 'Auto Rotate'],
];
const INDICATORS = [
    ['Gjs_status_remoteAccess_RemoteAccessApplet', 'Remote Access'], ['Gjs_status_camera_Indicator', 'Camera'],
    ['Gjs_status_volume_InputIndicator', 'Microphone'], ['Gjs_status_location_Indicator', 'Location'],
    ['Gjs_status_thunderbolt_Indicator', 'Thunderbolt'], ['Gjs_status_nightLight_Indicator', 'Night Light'],
    ['Gjs_status_network_Indicator', 'Network'], ['Gjs_status_bluetooth_Indicator', 'Bluetooth'],
    ['Gjs_status_rfkill_Indicator', 'Airplane Mode'], ['Gjs_status_volume_OutputIndicator', 'Volume'],
    ['Gjs_ui_panel_UnsafeModeIndicator', 'Unsafe Mode'], ['Gjs_status_system_Indicator', 'Power / System'],
];
const ITEMS = [
    ['battery', 'Battery'], ['laptopSpacer', 'Laptop Spacer'], ['screenshot', 'Screenshot button'],
    ['settings', 'Settings button'], ['desktopSpacer', 'Desktop Spacer'], ['lock', 'Lock button'], ['shutdown', 'Power button'],
];

function openOrderDialog(parent, title, entries, orderKey, hiddenKey, settings) {
    const labels = new Map(entries);
    const canonical = entries.map(e => e[0]);
    const win = new Adw.Window({ title, transient_for: parent, modal: true, default_width: 460, default_height: 640 });
    const page = new Adw.PreferencesPage();
    const group = new Adw.PreferencesGroup();
    page.add(group);
    const header = new Adw.HeaderBar();
    const reset = new Gtk.Button({ label: _('Reset') });
    header.pack_start(reset);
    const view = new Adw.ToolbarView({ content: page });
    view.add_top_bar(header);
    win.set_content(view);

    const loadOrder = () => {
        const saved = settings.get_strv(orderKey).filter(id => labels.has(id));
        return [...saved, ...canonical.filter(id => !saved.includes(id))];
    };
    let rows = [];
    const rebuild = () => {
        for (const r of rows)
            group.remove(r);
        rows = [];
        const order = loadOrder();
        const hidden = new Set(settings.get_strv(hiddenKey));
        order.forEach((id, i) => {
            const row = new Adw.ActionRow({ title: _(labels.get(id)) });
            const move = (d) => {
                const o = loadOrder();
                const j = i + d;
                if (j < 0 || j >= o.length)
                    return;
                [o[i], o[j]] = [o[j], o[i]];
                settings.set_strv(orderKey, o);
                rebuild();
            };
            const up = new Gtk.Button({ icon_name: 'go-up-symbolic', valign: Gtk.Align.CENTER, css_classes: ['flat'], sensitive: i > 0 });
            const down = new Gtk.Button({ icon_name: 'go-down-symbolic', valign: Gtk.Align.CENTER, css_classes: ['flat'], sensitive: i < order.length - 1 });
            up.connect('clicked', () => move(-1));
            down.connect('clicked', () => move(1));
            const hide = new Gtk.Switch({ valign: Gtk.Align.CENTER, active: hidden.has(id), tooltip_text: _('Hide') });
            hide.connect('notify::active', sw => {
                const h = new Set(settings.get_strv(hiddenKey));
                if (sw.active) h.add(id); else h.delete(id);
                settings.set_strv(hiddenKey, [...h]);
            });
            row.add_prefix(up);
            row.add_prefix(down);
            row.add_suffix(new Gtk.Label({ label: _('Hide'), css_classes: ['dim-label'] }));
            row.add_suffix(hide);
            group.add(row);
            rows.push(row);
        });
    };
    reset.connect('clicked', () => {
        settings.reset(orderKey);
        settings.reset(hiddenKey);
        rebuild();
    });
    rebuild();
    win.present();
}

export function addQsLayoutGroups(page, settings, window) {
    const group = new Adw.PreferencesGroup({ title: _('Quick Settings') });
    page.add(group);
    for (const [title, sub, entries, o, h] of [
        [_('Quick Toggles'), _('Reorder and hide the toggle tiles (unlisted toggles stay hidden)'), TOGGLES, 'qs-toggle-order', 'qs-toggle-hidden'],
        [_('System Indicators'), _('Reorder and hide the icons in the top bar'), INDICATORS, 'qs-indicator-order', 'qs-indicator-hidden'],
        [_('Bottom Row'), _('Reorder and hide the battery and button row'), ITEMS, 'qs-items-order', 'qs-items-hidden'],
    ]) {
        const row = new Adw.ActionRow({ title, subtitle: sub, activatable: true });
        row.add_suffix(new Gtk.Image({ icon_name: 'go-next-symbolic' }));
        row.connect('activated', () => openOrderDialog(window, title, entries, o, h, settings));
        group.add(row);
    }
    const dm = new Adw.SwitchRow({
        title: _('Hide date menu left box'),
        subtitle: _('Notifications and media controls'),
    });
    settings.bind('qs-datemenu-hide-left', dm, 'active', 0);
    group.add(dm);
    return group;
}
