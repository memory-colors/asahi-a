import { Gdk, Gio, GLib, Gtk } from './src/dependencies/prefs/gi.js';

import LayoutPrefs from './src/prefs/layoutsPrefs.js';
import { Shortcuts } from './src/common.js';
import './src/prefs/shortcutListener.js';

// Tiling Assistant's preferences, folded into Knomadic's Windows page (2026-10-25). Upstream prefs.js (v56) with these changes only:
// the class is a helper that hands Knomadic's prefs the pages instead of filling its own window, pages open as sub-pages of Knomadic's
// window, and the headerbar info button is a suffix of the Tiling group. All binding code below is upstream's, unchanged.
export class TilingPrefs {
    /** @param {Adw.PreferencesWindow} window Knomadic's prefs window; @param {string} path the tiling/ directory */
    constructor(window, path) {
        this._window = window;
        this._path = path;
    }

    /** Builds everything and returns { settings, pages: {general, keybindings, layouts, hidden}, infoMenu }. */
    build() {
        const window = this._window;
        const provider = new Gtk.CssProvider();
        provider.load_from_path(GLib.build_filenamev([this._path, 'stylesheet.css']));
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        window.set_can_navigate_back(true);

        // Same schema id + dconf path as the extension side (tiling/schemas)
        const source = Gio.SettingsSchemaSource.new_from_directory(
            GLib.build_filenamev([this._path, 'schemas']), Gio.SettingsSchemaSource.get_default(), false);
        const settings = new Gio.Settings({ settings_schema: source.lookup('org.gnome.shell.extensions.tiling-assistant', true) });
        const builder = new Gtk.Builder();
        builder.add_from_file(`${this._path}/src/ui/prefs.ui`);

        this._bindSwitches(settings, builder);
        this._bindSpinbuttons(settings, builder);
        this._bindComboRows(settings, builder);
        this._bindRadioButtons(settings, builder);
        this._bindKeybindings(settings, builder);
        this._bindColorButtons(settings, builder);

        // LayoutPrefs manages everything related to layouts on the prefs side (including the keyboard shortcuts)
        new LayoutPrefs(settings, builder, this._path);

        this._setDeprecatedSettings(settings, builder);
        this._addInfoActions(window, builder);

        return {
            settings,
            pages: {
                general: builder.get_object('general'),
                keybindings: builder.get_object('keybindings'),
                layouts: builder.get_object('layouts'),
                hidden: builder.get_object('hidden_settings'),
            },
            infoMenu: builder.get_object('info_menu'),
        };
    }

    /** Wraps a page for Adw.PreferencesWindow.present_subpage: the page plus upstream's own flat back button (same pattern as its hidden-settings page). */
    subpage(page) {
        const overlay = new Gtk.Overlay({ child: page });
        const back = new Gtk.Button({ icon_name: 'go-previous-symbolic', valign: Gtk.Align.START, halign: Gtk.Align.START, margin_start: 6, margin_top: 6 });
        back.add_css_class('flat');
        back.connect('clicked', () => this._window.close_subpage());
        overlay.add_overlay(back);
        return new Gtk.WindowHandle({ child: overlay });
    }

    /*
    * Bind GUI switches to settings.
    */
    _bindSwitches(settings, builder) {
        const switches = [
            'enable-tiling-popup',
            'tiling-popup-all-workspace',
            'enable-raise-tile-group',
            'tilegroups-in-app-switcher',
            'maximize-with-gap',
            'show-layout-panel-indicator',
            'enable-advanced-experimental-features',
            'disable-tile-groups',
            'low-performance-move-mode',
            'enable-layout-picker',
            'monitor-switch-grace-period',
            'adapt-edge-tiling-to-favorite-layout',
            'enable-tile-animations',
            'enable-untile-animations',
            'enable-hold-maximize-inverse-landscape',
            'enable-hold-maximize-inverse-portrait'
        ];

        switches.forEach(key => {
            const widget = builder.get_object(key.replaceAll('-', '_'));
            settings.bind(key, widget, 'active', Gio.SettingsBindFlags.DEFAULT);
        });
    }

    /*
    * Bind GUI spinbuttons to settings.
    */
    _bindSpinbuttons(settings, builder) {
        const spinButtons = [
            'window-gap',
            'single-screen-gap',
            'screen-top-gap',
            'screen-left-gap',
            'screen-right-gap',
            'screen-bottom-gap',
            'focus-hint-outline-size',
            'focus-hint-outline-border-radius',
            'toggle-maximize-tophalf-timer',
            'vertical-preview-area',
            'horizontal-preview-area'
        ];

        spinButtons.forEach(key => {
            const widget = builder.get_object(key.replaceAll('-', '_'));
            settings.bind(key, widget, 'value', Gio.SettingsBindFlags.DEFAULT);
        });
    }

    /*
    * Bind GUI AdwComboRows to settings.
    */
    _bindComboRows(settings, builder) {
        const comboRows = [
            'focus-hint-outline-style',
            'move-adaptive-tiling-mod',
            'move-favorite-layout-mod',
            'ignore-ta-mod'
        ];

        comboRows.forEach(key => {
            const widget = builder.get_object(key.replaceAll('-', '_'));
            settings.bind(key, widget, 'selected', Gio.SettingsBindFlags.DEFAULT);
            widget.set_selected(settings.get_int(key));
        });
    }

    /*
    * Bind GUI color buttons to settings.
    */
    _bindColorButtons(settings, builder) {
        const switches = [
            'focus-hint-color'
        ];

        switches.forEach(key => {
            const widget = builder.get_object(`${key.replaceAll('-', '_')}_button`);
            widget.connect('color-set', () => {
                settings.set_string(key, widget.get_rgba().to_string());
            });

            // initialize color
            const rgba = new Gdk.RGBA();
            rgba.parse(settings.get_string(key));
            widget.set_rgba(rgba);
        });
    }

    /*
    * Bind radioButtons to settings.
    */
    _bindRadioButtons(settings, builder) {
        // These 'radioButtons' are basically just used as a 'fake ComboBox' with
        // explanations for the different options. So there is just *one* gsetting
        // (an int) which saves the current 'selection'.
        const radioButtons = [
            {
                key: 'dynamic-keybinding-behavior',
                rowNames: [
                    'dynamic_keybinding_disabled_row',
                    'dynamic_keybinding_window_focus_row',
                    'dynamic_keybinding_tiling_state_row',
                    'dynamic_keybinding_tiling_state_windows_row',
                    'dynamic_keybinding_favorite_layout_row'
                ]
            },
            {
                key: 'focus-hint',
                rowNames: [
                    'disabled_focus_hint_row',
                    'animated_outline_focus_hint_row',
                    'animated_upscale_focus_hint_row',
                    'static_outline_focus_hint_row'
                ]
            },
            {
                key: 'default-move-mode',
                rowNames: [
                    'edge_tiling_row',
                    'adaptive_tiling_row',
                    'favorite_layout_row',
                    'ignore_ta_row'
                ]
            }
        ];

        radioButtons.forEach(({ key, rowNames }) => {
            const currActive = settings.get_int(key);

            rowNames.forEach((name, idx) => {
                const row = builder.get_object(name.replaceAll('-', '_'));
                const checkButton = row.activatable_widget;
                checkButton.connect('toggled', () => settings.set_int(key, idx));

                // Set initial state
                if (idx === currActive)
                    checkButton.activate();
            });
        });
    }

    /*
    * Bind keybinding widgets to settings.
    */
    _bindKeybindings(settings, builder) {
        const shortcuts = Shortcuts.getAllKeys();
        shortcuts.forEach(key => {
            const shortcut = builder.get_object(key.replaceAll('-', '_'));
            shortcut.initialize(key, settings);
        });
    }

    /**
     * Sets the visibility of deprecated settings. Those setting aren't visible
     * in the GUI unless they have a user set value. That means they aren't
     * discoverable through the GUI and need to first be set with the gsetting.
     * The normal rows should have the id of: GSETTING_WITH_UNDERSCORES_row.
     * ShortcutListeners have the format of GSETTING_WITH_UNDERSCORES.
     */
    _setDeprecatedSettings(settings, builder) {
        // Keybindings
        ['toggle-tiling-popup', 'auto-tile'].forEach(s => {
            const isNonDefault = settings.get_strv(s)[0] !== settings.get_default_value(s).get_strv()[0];
            builder.get_object(s.replaceAll('-', '_')).set_visible(isNonDefault);
        });

        // Switches
        ['tilegroups-in-app-switcher'].forEach(s => {
            const isNonDefault = settings.get_boolean(s) !== settings.get_default_value(s).get_boolean();
            builder.get_object(s.replaceAll('-', '_')).set_visible(isNonDefault);
        });
    }

    _addInfoActions(window, builder) {
        // Setup menu actions
        const actionGroup = new Gio.SimpleActionGroup();
        window.insert_action_group('prefs', actionGroup);

        const bugReportAction = new Gio.SimpleAction({ name: 'open-bug-report' });
        bugReportAction.connect('activate', this._openBugReport.bind(this, window));
        actionGroup.add_action(bugReportAction);

        const userGuideAction = new Gio.SimpleAction({ name: 'open-user-guide' });
        userGuideAction.connect('activate', this._openUserGuide.bind(this, window));
        actionGroup.add_action(userGuideAction);

        const changelogAction = new Gio.SimpleAction({ name: 'open-changelog' });
        changelogAction.connect('activate', this._openChangelog.bind(this, window));
        actionGroup.add_action(changelogAction);

        const licenseAction = new Gio.SimpleAction({ name: 'open-license' });
        licenseAction.connect('activate', this._openLicense.bind(this, window));
        actionGroup.add_action(licenseAction);

        const hiddenSettingsAction = new Gio.SimpleAction({ name: 'open-hidden-settings' });
        hiddenSettingsAction.connect('activate', this._openHiddenSettings.bind(this, window, builder));
        actionGroup.add_action(hiddenSettingsAction);

        // Button to return to main settings page
        const returnButton = builder.get_object('hidden_settings_return_button');
        returnButton.connect('clicked', () => window.close_subpage());
    }

    _openBugReport(window) {
        Gtk.show_uri(window, 'https://github.com/ubuntu/Tiling-Assistant/issues', Gdk.CURRENT_TIME);
    }

    _openUserGuide(window) {
        Gtk.show_uri(window, 'https://github.com/ubuntu/Tiling-Assistant/wiki', Gdk.CURRENT_TIME);
    }

    _openChangelog(window) {
        Gtk.show_uri(window, 'https://github.com/ubuntu/Tiling-Assistant/blob/main/CHANGELOG.md', Gdk.CURRENT_TIME);
    }

    _openLicense(window) {
        Gtk.show_uri(window, 'https://github.com/ubuntu/Tiling-Assistant/blob/main/LICENSE', Gdk.CURRENT_TIME);
    }

    _openHiddenSettings(window, builder) {
        const hiddenSettingsPage = builder.get_object('hidden_settings');
        window.present_subpage(hiddenSettingsPage);
    }
}
